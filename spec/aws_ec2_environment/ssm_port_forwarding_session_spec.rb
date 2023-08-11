# This is a stub for the reader IO pipe that is returned by +PTY.spawn+,
# which allows us to better test without spinning up a whole subprocess.
#
# Ideally we'd use a test double instead of a class, except we need a bit of state
# to implement +read_nonblock+ which would be messy to do with +instance_double(File)+.
#
# Generally its best to use the standard matchers & helpers for doubles rather
# than implement methods with any actual logic on this class (you will need to
# add empty methods to do partial doubling).
#
# We don't actually extend +File+ because we want to know what methods are called
# (à la +verify_partial_doubles+) and as we can't trust parent methods to work
# correctly given we've not an actual pipe.
class SsmProcessReaderStub
  def initialize(buffer, exited)
    @buffer = buffer
    @exited = exited
  end

  def read_nonblock(maxlen)
    if @buffer.empty?
      # if the subprocess is exited, then the buffer is empty this errno is thrown
      # TODO: (at least on Ubuntu 20.04, test with MacOS!)
      raise Errno::EIO if @exited

      raise IO::EAGAINWaitReadable
    end

    @buffer.slice!(0, maxlen)
  end

  def close; end
end

RSpec.describe AwsEc2Environment::SsmPortForwardingSession do
  subject(:session) do
    described_class.new(
      "i-0d9c4bg3f26157a8e",
      22,
      logger: Logger.new(StringIO.new(log)),
      # we can use a really low timeout to make the tests a lot faster,
      # since we're not actually going to be writing asynchronously
      timeout: 0.00001
    )
  end

  let(:log) { "" }
  let(:reader) { SsmProcessReaderStub.new("Starting session with SessionId: #{session_id}\n", false) }
  let(:writer) { instance_double(File) }
  let(:ssm_client) { instance_double(Aws::SSM::Client) }
  let(:session_id) { "botocore-session-1659667492-0f93356199500fb5f" }

  before do
    allow(PTY).to receive(:spawn).and_return([reader, writer, 1234])

    allow(writer).to receive(:close)

    allow(Aws::SSM::Client).to receive(:new).and_return(ssm_client)
  end

  describe ".new" do
    it "runs the expected command with the flags escaped" do
      expect { session }.not_to raise_error

      parameters = { "portNumber" => ["22"] }
      parameters_escaped = Shellwords.escape(parameters.to_json)

      expect(PTY).to have_received(:spawn).with(
        %w[
          aws ssm start-session
          --target i-0d9c4bg3f26157a8e
          --document-name AWS-StartPortForwardingSession
          --parameters
        ].join(" ") + " #{parameters_escaped}"
      )
    end

    it "grabs the session id from the session-manager-plugin" do
      expect { session }.not_to raise_error

      expect(log).to include("SSM session #{session_id} opening")
    end

    context "when a local_port is provided" do
      subject(:session) do
        described_class.new(
          "i-0d9c4bg3f26157a8e",
          22,
          local_port: 9999,
          logger: Logger.new(StringIO.new(log)),
          # we can use a really low timeout to make the tests a lot faster,
          # since we're not actually going to be writing asynchronously
          timeout: 0.00001
        )
      end

      it "includes that in the SSM document parameters" do
        expect { session }.not_to raise_error

        parameters = { "portNumber" => ["22"], "localPortNumber" => ["9999"] }
        parameters_escaped = Shellwords.escape(parameters.to_json)

        expect(PTY).to have_received(:spawn).with(
          %w[
            aws ssm start-session
            --target i-0d9c4bg3f26157a8e
            --document-name AWS-StartPortForwardingSession
            --parameters
          ].join(" ") + " #{parameters_escaped}"
        )
      end
    end

    context "when a reason is provided" do
      subject(:session) do
        described_class.new(
          "i-0d9c4bg3f26157a8e",
          22,
          logger: Logger.new(StringIO.new(log)),
          # we can use a really low timeout to make the tests a lot faster,
          # since we're not actually going to be writing asynchronously
          timeout: 0.00001,
          reason: "hello world"
        )
      end

      it "includes that in the SSM command" do
        expect { session }.not_to raise_error

        parameters = { "portNumber" => ["22"] }
        parameters_escaped = Shellwords.escape(parameters.to_json)

        expect(PTY).to have_received(:spawn).with(
          %w[
            aws ssm start-session
            --target i-0d9c4bg3f26157a8e
            --document-name AWS-StartPortForwardingSession
            --parameters
          ].join(" ") + " #{parameters_escaped} --reason hello\\ world"
        )
      end
    end

    context "when the expected text does not appear" do
      let(:reader) { SsmProcessReaderStub.new("", false) }

      it "errors" do
        expect { session }.to raise_error(AwsEc2Environment::SsmPortForwardingSession::SessionIdNotFoundError)
      end
    end

    context "when the session-manager-plugin exits with output" do
      let(:reader) do
        SsmProcessReaderStub.new(
          "Unable to locate credentials. You can configure credentials by running \"aws configure\".\n\n",
          true
        )
      end

      it "errors with the subprocess output" do
        expect { session }.to raise_error(
          AwsEc2Environment::SsmPortForwardingSession::SessionProcessError,
          "Unable to locate credentials. You can configure credentials by running \"aws configure\"."
        )
      end
    end

    context "when the session-manager-plugin exits without output" do
      let(:reader) { SsmProcessReaderStub.new("", true) }

      it "errors with a fallback message" do
        expect { session }.to raise_error(
          AwsEc2Environment::SsmPortForwardingSession::SessionProcessError,
          "<nothing was outputted by process>"
        )
      end
    end
  end

  describe "#instance_id" do
    it "returns the expected value" do
      expect(session.instance_id).to eql "i-0d9c4bg3f26157a8e"
    end
  end

  describe "#remote_port" do
    it "returns the expected value" do
      expect(session.remote_port).to be 22
    end
  end

  describe "#pid" do
    it "returns the expected value" do
      expect(session.pid).to be 1234
    end
  end

  describe "#wait_for_local_port" do
    let(:reader) do
      SsmProcessReaderStub.new(
        <<~STDOUT,
          Starting session with SessionId: #{session_id}
          Port 9876 opened for sessionId #{session_id}.
          Waiting for connections...
        STDOUT
        false
      )
    end

    it "returns the local port once found" do
      expect(session.wait_for_local_port).to be 9876
    end

    it "returns the same value when called multiple times" do
      expect(session.wait_for_local_port).to be 9876
      expect(session.wait_for_local_port).to be 9876
    end

    it "returns the port used by the session-manager-plugin" do
      session = described_class.new(
        "i-0d9c4bg3f26157a8e",
        22,
        local_port: 9999,
        logger: Logger.new(StringIO.new(log)),
        # we can use a really low timeout to make the tests a lot faster,
        # since we're not actually going to be writing asynchronously
        timeout: 0.00001
      )

      expect(session.wait_for_local_port).to be 9876
    end

    context "when the expected test does not appear" do
      let(:reader) { SsmProcessReaderStub.new("Starting session with SessionId: #{session_id}\n", false) }

      it "errors" do
        expect { session.wait_for_local_port }.to raise_error(
          AwsEc2Environment::SsmPortForwardingSession::SessionTimedOutError
        )
      end
    end
  end

  describe "#close" do
    before do
      allow(reader).to receive(:close)
      allow(ssm_client).to receive(:terminate_session).and_return(
        Aws::SSM::Types::TerminateSessionResponse.new(session_id: session_id)
      )
    end

    # TODO: when do we expect there to not be a session...? (maybe if calling #close multiple times?)
    context "when there is an active session" do
      it "has AWS terminate the session" do
        session.close

        expect(ssm_client).to have_received(:terminate_session).with({ session_id: session_id })
        expect(log).to include("Terminated SSM session #{session_id} successfully")
      end
    end

    it "closes the reader" do
      session.close

      expect(reader).to have_received(:close)
    end

    it "closes the writer" do
      session.close

      expect(writer).to have_received(:close)
    end
  end
end
