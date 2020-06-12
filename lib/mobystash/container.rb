# frozen_string_literal: true
require 'deep_merge'
require 'murmurhash3'

module Mobystash
  # Hoovers up logs for a single container and passes them on to the writer.
  class Container
    include Mobystash::MobyEventWorker

    # This is needed because floats are terribad at this level of precision,
    # and it works because Time happens to be based on Rational.
    #
    ONE_NANOSECOND = Rational('1/1000000000')
    private_constant :ONE_NANOSECOND

    SYSLOG_FACILITIES = %w{
      kern
      user
      mail
      daemon
      auth
      syslog
      lpr
      news
      uucp
      cron
      authpriv
      ftp
      reserved12 reserved13 reserved14 reserved15
      local0 local1 local2 local3 local4 local5 local6 local7
    }

    SYSLOG_SEVERITIES = %w{
      emerg
      alert
      crit
      err
      warning
      notice
      info
      debug
    }

    private_constant :SYSLOG_FACILITIES, :SYSLOG_SEVERITIES

    # docker_data is the Docker::Container instance representing the moby
    # container metadata, and system_config is the Mobystash::Config.
    #
    def initialize(docker_data, system_config, last_log_timestamp: nil)
      @id = docker_data.id

      @config  = system_config
      @logger  = @config.logger
      @writer  = @config.logstash_writer
      @sampler = @config.sampler

      @name = (docker_data.info["Name"] || docker_data.info["Names"].first).sub(/\A\//, '')

      if docker_data.info["Config"]["Tty"]
        @config.log_entries_read_counter.increment({ container_name: @name, container_id: @id, stream: "tty" }, 0)
      else
        @config.log_entries_read_counter.increment({ container_name: @name, container_id: @id, stream: "stdout" }, 0)
        @config.log_entries_read_counter.increment({ container_name: @name, container_id: @id, stream: "stderr" }, 0)
      end

      @capture_logs = true
      @parse_syslog = false

      @tags = {
        moby: {
          name: @name,
          id: @id,
          hostname: docker_data.info["Config"]["Hostname"],
          image: docker_data.info["Config"]["Image"],
          image_id: docker_data.info["Image"],
        }
      }

      @last_log_timestamp = last_log_timestamp || Time.at(0).utc.strftime("%FT%T.%NZ")
      @llt_mutex = Mutex.new

      parse_labels(docker_data.info["Config"]["Labels"])

      super

      @logger.debug(progname) do
        (["Created new container listener.  Instance variables:"] + %i{@name @capture_logs @parse_syslog @tags @last_log_timestamp}.map do |iv|
          "#{iv}=#{instance_variable_get(iv).inspect}"
        end).join("\n  ")
      end
    end

    # The timestamp, in RFC3339 format, of the last log message which was
    # received by this container.
    def last_log_timestamp
      @llt_mutex.synchronize { @last_log_timestamp }
    end

    private

    def progname
      @logger_progname ||= "Mobystash::Container(#{short_id})"
    end

    def docker_host
      @config.docker_host
    end

    def logger
      @logger
    end

    def event_exception(ex)
      @config.read_event_exception_counter.increment(container_name: @name, container_id: @id, class: ex.class.to_s)
    end

    def short_id
      @id[0..11]
    end

    def parse_labels(labels)
      @logger.debug(progname) { "Parsing labels: #{labels.inspect}" }

      labels.each do |lbl, val|
        case lbl
        when "org.discourse.mobystash.disable"
          @logger.debug(progname) { "Found disable label, value: #{val.inspect}" }
          @capture_logs = !(val =~ /\Ayes|y|1|on|true|t\z/i)
          @logger.debug(progname) { "@capture_logs is now #{@capture_logs.inspect}" }
        when "org.discourse.mobystash.filter_regex"
          @logger.debug(progname) { "Found filter_regex label, value: #{val.inspect}" }
          @filter_regex = Regexp.new(val)
        when /\Aorg\.discourse\.mobystash\.tag\.(.*)\z/
          @logger.debug(progname) { "Found tag label #{$1}, value: #{val.inspect}" }
          @tags.deep_merge!(hashify_tag($1, val))
          @logger.debug(progname) { "Container tags is now #{@tags.inspect}" }
        when "org.discourse.mobystash.parse_syslog"
          @logger.debug(progname) { "Found parse_syslog label, value: #{val.inspect}" }
          @parse_syslog = !!(val =~ /\Ayes|y|1|on|true|t\z/i)
        end
      end
    end

    # Turn a dot-separated sequence of strings into a nested hash.
    #
    # @example
    #    hashify_tag("a.b.c", "42")
    #    => { a: { b: { c: "42" } } }
    #
    def hashify_tag(tag, val)
      if tag.index(".")
        tag, rest = tag.split(".", 2)
        { tag.to_sym => hashify_tag(rest, val) }
      else
        { tag.to_sym => val }
      end
    end

    def process_events(conn)
      begin
        if tty?(conn)
          @config.log_entries_sent_counter.increment({ container_name: @name, container_id: @id, stream: "tty" }, 0)
        else
          @config.log_entries_sent_counter.increment({ container_name: @name, container_id: @id, stream: "stdout" }, 0)
          @config.log_entries_sent_counter.increment({ container_name: @name, container_id: @id, stream: "stderr" }, 0)
        end

        if @capture_logs
          unless Docker::Container.get(@id, {}, conn).info.fetch("State", {})["Status"] == "running"
            @logger.debug(progname) { "Container is not running; waiting for it to start or be destroyed" }
            wait_for_container_to_start(conn)
          else
            @logger.debug(progname) { "Capturing logs since #{@last_log_timestamp}" }

            # The implementation of Docker::Container#streaming_logs has a
            # *terribad* memory leak, in that every log entry that gets received
            # gets stored in a couple of arrays, which only gets cleared when
            # the call to #streaming_logs finishes... which is bad, because
            # we like these to go on for a long time.  So, instead, we need to
            # do our own thing directly, by hand.
            chunk_parser = Mobystash::MobyChunkParser.new(tty: tty?(conn)) do |msg, s|
              send_event(msg, s)
            end

            conn.get(
              "/containers/#{@id}/logs",
              {
                since: (Time.strptime(@last_log_timestamp, "%FT%T.%N%Z") + ONE_NANOSECOND).strftime("%s.%N"),
                timestamps: true,
                follow: true,
                stdout: true,
                stderr: true,
              },
              idempotent: false,
              response_block: chunk_parser
            )
          end
        else
          @logger.debug(progname) { "Not capturing logs because mobystash is disabled" }
          sleep
        end
      rescue Docker::Error::NotFoundError, Docker::Error::ServerError
        # This happens when the container terminates, but we beat the System
        # in the race and we call Docker::Container.get before the System
        # shuts us down.  Since we'll be terminated soon anyway, we may as
        # well do it first.
        @logger.info(progname) { "Container has terminated." }
        raise TerminateEventWorker
      end
    end

    def wait_for_container_to_start(conn)
      @logger.debug(progname) { "Asking for events since #{@last_log_timestamp}" }

      Docker::Event.since((Time.strptime(@last_log_timestamp, "%FT%T.%N%Z") + ONE_NANOSECOND).strftime("%s.%N"), {}, conn) do |event|
        @last_log_timestamp = event.time

        @logger.debug(progname) { "Docker event@#{event.timeNano}: #{event.Type}.#{event.Action} on #{event.ID}" }

        break if event.Type == "container" && event.ID == @id
      end
    end

    def send_event(msg, stream)
      @config.log_entries_read_counter.increment(container_name: @name, container_id: @id, stream: stream)

      @llt_mutex.synchronize do
        @last_log_timestamp, msg = msg.chomp.split(' ', 2)
      end

      @config.last_log_entry_at.observe(
        Time.strptime(@last_log_timestamp, "%FT%T.%N%Z").to_f,
        container_name: @name, container_id: @id, stream: stream.to_s
      )

      msg, syslog_fields = if @parse_syslog
        parse_syslog(msg)
      else
        [msg, {}]
      end

      passed, sampling_metadata = @sampler.sample(msg)

      return unless passed

      # match? is faster cause no globals are set
      if !@filter_regex || !msg.match?(@filter_regex)
        event = {
          message: msg,
          "@timestamp": @last_log_timestamp,
          moby: {
            stream: stream.to_s,
          },
        }.deep_merge(syslog_fields).deep_merge(sampling_metadata).deep_merge!(@tags)

        # Can't calculate the document_id until you've got a constructed event...
        metadata = {
          "@metadata": {
            document_id: MurmurHash3::V128.murmur3_128_str_base64digest(event.to_json)[0..-3],
            event_type: "moby",
          }
        }

        event = event.deep_merge(metadata)

        @config.logstash_writer.send_event(event)
        @config.log_entries_sent_counter.increment(container_name: @name, container_id: @id, stream: stream.to_s)
      end
    end

    def parse_syslog(msg)
      if msg =~ /\A<(\d+)>(\w{3} [ 0-9]{2} [0-9:]{8}) (.*)\z/
        flags     = $1.to_i
        timestamp = $2
        content   = $3

        # Lo! the many ways that syslog messages can be formatted
        hostname, program, pid, message =
        case content
        # the gold standard: hostname, program name with optional PID
        when /^([a-zA-Z0-9._-]*[^:]) (\S+?)(\[(\d+)\])?: (.*)$/
          [$1, $2, $4, $5]
        # hostname, no program name
        when /^([a-zA-Z0-9._-]+) (\S+[^:] .*)$/
          [$1, nil, nil, $2]
        # program name, no hostname (yeah, you heard me, non-RFC compliant!)
        when /^(\S+?)(\[(\d+)\])?: (.*)$/
          [nil, $1, $3, $4]
        else
          # I have NFI
          [nil, nil, nil, content]
        end

        severity = flags % 8
        facility = flags / 8

        [message, { syslog: {
          timestamp: timestamp,
          severity_id: severity,
          severity_name: SYSLOG_SEVERITIES[severity],
          facility_id: facility,
          facility_name: SYSLOG_FACILITIES[facility],
          hostname: hostname,
          program: program,
          pid: pid.nil? ? nil : pid.to_i,
        }.select { |k, v| !v.nil? } }]
      else
        [msg, {}]
      end
    end

    def tty?(conn)
      @tty ||= Docker::Container.get(@id, {}, conn).info["Config"]["Tty"]
    end
  end
end
