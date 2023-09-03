require "aws-sdk-ssm"
require "pty"
require "timeout"
require "shellwords"
require "json"

class AwsEc2Environment
  class SsmPortForwardingSession
    class SessionIdNotFoundError < Error; end
    class SessionTimedOutError < Error; end
    class SessionProcessError < Error; end

    # @return [String]
    attr_reader :instance_id

    # @return [Number]
    attr_reader :remote_port

    # @return [String]
    attr_reader :pid

    # rubocop:disable Metrics/ParameterLists
    def initialize(
      instance_id, remote_port,
      local_port: nil, logger: Logger.new($stdout),
      timeout: 15, reason: nil
    )
      # rubocop:enable Metrics/ParameterLists
      @logger = logger
      @instance_id = instance_id
      @remote_port = remote_port
      @local_port = nil
      @timeout = timeout

      @reader, @writer, @pid = PTY.spawn(ssm_port_forward_cmd(local_port, reason))

      @cmd_output = ""
      @session_id = wait_for_session_id

      @logger.info("SSM session #{@session_id} opening, forwarding port #{remote_port} on #{instance_id}")
    end

    def close
      @logger.info "Terminating SSM session #{@session_id}..."
      resp = Aws::SSM::Client.new.terminate_session({ session_id: @session_id })
      @logger.info "Terminated SSM session #{resp.session_id} successfully"

      @reader.close
      @writer.close
    end

    def wait_for_local_port
      _, local_port = expect_cmd_output(/Port (\d+) opened for sessionId #{@session_id}.\r?\n/, @timeout) || []

      if local_port.nil?
        raise(
          SessionTimedOutError,
          "SSM session #{@session_id} did not become ready within #{@timeout} seconds (maybe increase the timeout?)"
        )
      end

      local_port.to_i
    end

    private

    def ssm_port_forward_cmd(local_port, reason)
      document_name = "AWS-StartPortForwardingSession"
      parameters = { "portNumber" => [remote_port.to_s] }
      parameters["localPortNumber"] = [local_port.to_s] unless local_port.nil?
      flags = [
        ["--target", instance_id],
        ["--document-name", document_name],
        ["--parameters", parameters.to_json]
      ]

      flags << ["--reason", reason] unless reason.nil?
      flags = flags.map { |(flag, value)| "#{flag} #{Shellwords.escape(value)}" }.join(" ")

      "aws ssm start-session #{flags}"
    end

    # Checks the cmd process output until either the given +pattern+ matches or the +timeout+ is over.
    #
    # It returns an array with the result of the match or otherwise +nil+.
    #
    # This is effectively a re-implementation of the +File#expect+ method except it captures
    # the cmd process output over time so we can include it in the case of errors
    def expect_cmd_output(pattern, timeout)
      Timeout.timeout(timeout) do
        loop do
          update_cmd_output

          match = @cmd_output.match(pattern)

          return match.to_a unless match.nil?
        end
      end
    rescue Timeout::Error
      nil
    end

    # Updates the tracked output of the cmd process with any new data that is available in the buffer,
    # until the next read will block at which point this method returns.
    def update_cmd_output
      loop do
        @cmd_output << @reader.read_nonblock(1)

        # next unless @cmd_output[-1] == "\n"
        #
        # last_newline = @cmd_output.rindex("\n", -2) || 0
        # puts @cmd_output.slice(last_newline + 1, @cmd_output.length) if @cmd_output[-1] == "\n"
      end
    rescue IO::EAGAINWaitReadable
      # do nothing as we don't want to block
    rescue Errno::EIO
      output = @cmd_output.strip
      # output = "<nothing was outputted by process>" if output.empty?

      raise SessionProcessError, output
    end

    def wait_for_session_id
      _, session_id = expect_cmd_output(/Starting session with SessionId: ([=,.@\w-]+)\r?\n/, @timeout) || []

      if session_id.nil?
        raise(
          SessionIdNotFoundError,
          "could not find session id within #{@timeout} seconds - SSM plugin output: #{@cmd_output}"
        )
      end

      session_id
    end
  end
end
