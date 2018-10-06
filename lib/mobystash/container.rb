require 'deep_merge'
require 'logstash_writer'
require 'murmurhash3'

require 'mobystash/moby_event_worker'

module Mobystash
  # Hoovers up logs for a single container and passes them on to the writer.
  class Container
    include Mobystash::MobyEventWorker

    # docker_data is the Docker::Container instance representing the moby
    # container metadata, and system_config is the Mobystash::Config.
    #
    def initialize(docker_data, system_config)
      @id = docker_data.id

      @config = system_config
      @logger = @config.logger
      @writer = @config.logstash_writer

      @name = (docker_data.info["Name"] || docker_data.info["Names"].first).sub(/\A\//, '')

      @capture_logs = true
      @tags = {
        moby: {
          name:     @name,
          id:       @id,
          hostname: docker_data.info["Config"]["Hostname"],
          image:    docker_data.info["Config"]["Image"],
          image_id: docker_data.info["Image"],
        }
      }

      @last_log_timestamp = Time.at(0)

      parse_labels(docker_data.info["Config"]["Labels"])

      super
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
          @capture_logs = !(val =~ /\Ayes|1|on|true\z/i)
          @logger.debug(progname) { "@capture_logs is now #{@capture_logs.inspect}" }
        when "org.discourse.mobystash.filter_regex"
          @logger.debug(progname) { "Found filter_regex label, value: #{val.inspect}" }
          @filter_regex = Regexp.new(val)
        when /\Aorg\.discourse\.mobystash\.tag\.(.*)\z/
          @logger.debug(progname) { "Found tag label #{$1}, value: #{val.inspect}" }
          @tags.deep_merge!(hashify_tag($1, val))
          @logger.debug(progname) { "Container tags is now #{@tags.inspect}" }
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
      if @capture_logs
        @logger.debug(progname) { "Capturing logs since #{@last_log_timestamp.strftime("%FT%T.%NZ")}" }

        begin
          c = Docker::Container.get(@id, {}, conn)
          c.streaming_logs(since: @last_log_timestamp.strftime("%s.%N"), timestamps: true, follow: true, stdout: true, stderr: true, tty: c.info["Config"]["Tty"]) do |s, msg|
            # Le sigh... normally, the first argument is the stream and the
            # second is the message, but if we're running a TTY, the first argument is actually
            # the message and the second argument is nil.  WHYYYYYYYYYYY?!??!
            if msg.nil?
              msg = s
              s = :tty
            end

            send_event(msg, s)
          end
        rescue Docker::Error::NotFoundError
          # This happens when the container terminates, but we beat the System
          # in the race and we call Docker::Container.get before the System
          # shuts us down.  Since we'll be terminated soon anyway, we may as
          # well do it first.
          @logger.info(progname) { "Container has terminated." }
          raise TerminateEventWorker
        end
      else
        @logger.debug(progname) { "Not capturing logs because mobystash is disabled" }
        sleep
      end
    end

    def send_event(msg, stream)
      @config.log_entries_read_counter.increment(container_name: @name, container_id: @id, stream: stream)

      ts, msg = msg.chomp.split(' ', 2)
      @last_log_timestamp = Time.strptime(ts, "%FT%T.%N%Z")
      unless @filter_regex && @filter_regex =~ msg
        event = {
          message: msg,
          "@timestamp": ts,
          moby: {
            stream: stream.to_s,
          },
        }.deep_merge!(@tags)

        # Can't calculate the document_id until you've got a constructed event...
        metadata = {
          "@metadata": {
            document_id: MurmurHash3::V128.murmur3_128_str_base64digest(event.to_json)[0..-3],
            event_type:  "moby",
          }
        }

        event = event.deep_merge(metadata)

        @config.logstash_writer.send_event(event)
        @config.log_entries_sent_counter.increment(container_name: @name, container_id: @id, stream: stream)
      end
    end
  end
end
