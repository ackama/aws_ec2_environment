require "spec_helper"
require "json"

# Creates a new Logger which logs to the given +str+
#
# @param [StringIO] str
#
# @return [Logger]
def str_logger(str = StringIO.new)
  Logger.new(str)
end

def mock_ec2_describe_instances(ec2_client, instances)
  allow(ec2_client).to receive(:describe_instances).and_return(
    instance_double(
      Aws::EC2::Types::DescribeInstancesResult,
      reservations: [
        instance_double(
          Aws::EC2::Types::Reservation,
          instances: instances.map { |attrs| instance_double(Aws::EC2::Instance, **attrs) }
        )
      ]
    )
  )
end

RSpec.describe AwsEc2Environment do
  subject(:instances) do
    described_class.new(
      AwsEc2Environment::Config.new(:production, JSON.parse(config.to_json)),
      logger: str_logger
    )
  end

  let(:ec2_client) { instance_double(Aws::EC2::Client) }
  let(:ssm_port_forwarding_session) { instance_double(AwsEc2Environment::SsmPortForwardingSession) }
  let(:config) do
    {
      aws_region: "ap-southeast-2",
      ssh_user: "ubuntu",
      filters: [
        { name: "instance-state-name", values: ["running"] },
        { name: "tag:Name", values: ["ProductionAppServer"] }
      ]
    }
  end

  before do
    allow(Aws::EC2::Client).to receive(:new).and_return(ec2_client)
    allow(AwsEc2Environment::SsmPortForwardingSession).to receive(:new).and_return(ssm_port_forwarding_session)
  end

  describe ".from_yaml_file" do
    let(:config_file_path) { "spec/sample-config.yml" }

    it "uses the config for the given environment" do
      instances = described_class.from_yaml_file(config_file_path, :production)

      expect(instances.config.env_name).to be :production
    end

    context "when the environment is not present" do
      it "errors" do
        expect { described_class.from_yaml_file(config_file_path, :uat) }.to raise_error(
          AwsEc2Environment::EnvironmentConfigNotFound,
          "#{config_file_path} does not have an environment named \"uat\""
        )
      end
    end
  end

  describe "#ips" do
    context "when there are instances with public ips" do
      before do
        mock_ec2_describe_instances(
          ec2_client,
          [
            { public_ip_address: "31.1.2.3", private_ip_address: "192.1.2.3" },
            { public_ip_address: "78.3.2.1", private_ip_address: "127.1.2.3" }
          ]
        )
      end

      it "returns the public ips of the instances" do
        expect(instances.ips).to eq %w[31.1.2.3 78.3.2.1]
      end
    end

    context "when there are instances without public ips" do
      before do
        mock_ec2_describe_instances(
          ec2_client,
          [
            { private_ip_address: "192.1.2.3", public_ip_address: nil },
            { private_ip_address: "127.1.2.3", public_ip_address: "78.3.2.1" }
          ]
        )
      end

      it "returns the private ip for those instances" do
        expect(instances.ips).to eq %w[192.1.2.3 78.3.2.1]
      end
    end

    context "when no instances are found" do
      before { mock_ec2_describe_instances(ec2_client, []) }

      it "returns an empty array" do
        expect(instances.ips).to eql []
      end
    end
  end

  describe "#ids" do
    before do
      mock_ec2_describe_instances(
        ec2_client,
        [
          { instance_id: "i-0d9c4bg3f26157a8e" },
          { instance_id: "i-8fd915abg740e63c2" }
        ]
      )
    end

    it "returns the ids of all instances matched by the filters" do
      expect(instances.ids).to eql %w[i-0d9c4bg3f26157a8e i-8fd915abg740e63c2]
    end

    it "only uses the instance_filters" do
      instances.ids

      expect(ec2_client).to have_received(:describe_instances).with(
        filters: [
          { "name" => "instance-state-name", "values" => ["running"] },
          { "name" => "tag:Name", "values" => ["ProductionAppServer"] }
        ]
      )
    end

    context "when no instances are found" do
      before { mock_ec2_describe_instances(ec2_client, []) }

      it "returns an empty array" do
        expect(instances.ids).to eql []
      end
    end
  end

  describe "#hosts_for_sshing" do
    let(:ssm_pfs_class) { class_double(AwsEc2Environment::SsmPortForwardingSession, new: ssm_port_forwarding_session) }

    before do
      ssm_pfs_class.as_stubbed_const
      mock_ec2_describe_instances(
        ec2_client,
        [
          { instance_id: "i-0d9c4bg3f26157a8e", public_ip_address: "31.1.2.3" },
          { instance_id: "i-8fd915abg740e63c2", public_ip_address: "78.3.2.1" }
        ]
      )
    end

    it "returns the ips of the matched instances" do
      expect(instances.hosts_for_sshing).to eql %w[31.1.2.3 78.3.2.1]
    end

    it "does not start any port forwarding sessions with SSM" do
      instances.hosts_for_sshing

      expect(ssm_pfs_class).not_to have_received(:new)
    end

    context "when use_ssm is true" do
      let(:config) { super().merge({ use_ssm: true, ssm_host: "ec2.\#{id}.local.ackama.app" }) }

      before do
        allow(ssm_port_forwarding_session).to receive(:wait_for_local_port).and_return(9999, 9998)
        ssm_pfs_class.as_stubbed_const
      end

      it "returns the expected hosts with the forwarded port" do
        expect(instances.hosts_for_sshing).to eql %w[
          ec2.i-0d9c4bg3f26157a8e.local.ackama.app:9999
          ec2.i-8fd915abg740e63c2.local.ackama.app:9998
        ]
      end

      it "starts a port forwarding session for each instance" do
        instances.hosts_for_sshing

        expected_hash = hash_including({})

        expect(ssm_pfs_class).to have_received(:new).with("i-0d9c4bg3f26157a8e", 22, expected_hash).once
        expect(ssm_pfs_class).to have_received(:new).with("i-8fd915abg740e63c2", 22, expected_hash).once
      end

      it "includes a good reason when running in CI" do
        allow(AwsEc2Environment::CiService).to receive(:detect).and_return({ name: "GitHub Actions", build_id: "1234" })

        instances.hosts_for_sshing

        reason = "GitHub Actions, build 1234"
        expected_hash = hash_including({ reason: reason })

        expect(ssm_pfs_class).to have_received(:new).with("i-0d9c4bg3f26157a8e", 22, expected_hash).once
        expect(ssm_pfs_class).to have_received(:new).with("i-8fd915abg740e63c2", 22, expected_hash).once
      end

      it "includes a good reason when running locally" do
        allow(AwsEc2Environment::CiService).to receive(:detect).and_return(nil)
        allow(Socket).to receive(:gethostname).and_return("DESKTOP-DQB4BNG")

        stub_const("ENV", ENV.to_hash.merge("USER" => "bob"))

        instances.hosts_for_sshing

        reason = "bob@DESKTOP-DQB4BNG"
        expected_hash = hash_including({ reason: reason })

        expect(ssm_pfs_class).to have_received(:new).with("i-0d9c4bg3f26157a8e", 22, expected_hash).once
        expect(ssm_pfs_class).to have_received(:new).with("i-8fd915abg740e63c2", 22, expected_hash).once
      end
    end
  end

  describe "#use_bastion_server?" do
    it "returns false" do
      expect(instances.use_bastion_server?).to be false
    end

    context "when there are filters for a bastion instance" do
      let(:config) do
        super().merge(
          {
            bastion_instance: [
              { name: "instance-state-name", values: ["running"] },
              { name: "tag:Name", values: ["ProductionBastion"] }
            ]
          }
        )
      end

      it "returns true" do
        expect(instances.use_bastion_server?).to be true
      end
    end
  end

  describe "#bastion_public_ip" do
    let(:config) do
      super().merge(
        {
          bastion_instance: [
            { name: "instance-state-name", values: ["running"] },
            { name: "tag:Name", values: ["ProductionBastion"] }
          ]
        }
      )
    end

    context "without bastion filters in the config" do
      let(:config) { super().merge({ bastion_instance: nil }) }

      it "errors" do
        expect { instances.bastion_public_ip }.to raise_error AwsEc2Environment::BastionNotExpectedError
      end
    end

    context "when no instances are matched by the bastion filters" do
      before { mock_ec2_describe_instances(ec2_client, []) }

      it "errors" do
        expect { instances.bastion_public_ip }.to raise_error(
          AwsEc2Environment::BastionNotFoundError,
          "0 potential bastion instances were found - " \
          "please ensure your filters are specific enough to only return a single instance"
        )
      end
    end

    context "when one instance is matched by the bastion filters" do
      before do
        mock_ec2_describe_instances(
          ec2_client,
          [{ public_ip_address: "31.1.2.3", private_ip_address: "192.1.2.3" }]
        )
      end

      it "returns the public ip of the instance" do
        expect(instances.bastion_public_ip).to eql "31.1.2.3"
      end

      it "errors if the instance does not have a public ip" do
        mock_ec2_describe_instances(ec2_client, [{ public_ip_address: nil, private_ip_address: "192.1.2.3" }])

        expect { instances.bastion_public_ip }.to raise_error(
          AwsEc2Environment::BastionNotFoundError,
          "a potential bastion instance was found, but it does not have a public ip"
        )
      end
    end

    context "when multiple instances are matched by the bastion filters" do
      before do
        mock_ec2_describe_instances(
          ec2_client,
          [
            { public_ip_address: "31.1.2.3", private_ip_address: "192.1.2.3" },
            { public_ip_address: "78.3.2.1", private_ip_address: "127.1.2.3" }
          ]
        )
      end

      it "errors" do
        expect { instances.bastion_public_ip }.to raise_error(
          AwsEc2Environment::BastionNotFoundError,
          "2 potential bastion instances were found - " \
          "please ensure your filters are specific enough to only return a single instance"
        )
      end
    end
  end

  describe "#build_ssh_bastion_proxy_command" do
    let(:config) do
      super().merge(
        {
          bastion_instance: [
            { name: "instance-state-name", values: ["running"] },
            { name: "tag:Name", values: ["ProductionBastion"] }
          ]
        }
      )
    end

    before { mock_ec2_describe_instances(ec2_client, [{ public_ip_address: "31.1.2.3" }]) }

    it "returns the expected command" do
      expect(instances.build_ssh_bastion_proxy_command).to eql(
        "ssh -o StrictHostKeyChecking=no ubuntu@31.1.2.3 -W %h:%p"
      )
    end

    context "without bastion filters in the config" do
      let(:config) { super().merge({ bastion_instance: nil }) }

      it "errors" do
        expect { instances.build_ssh_bastion_proxy_command }.to raise_error AwsEc2Environment::BastionNotExpectedError
      end
    end
  end

  describe "#stop_ssh_port_forwarding_sessions" do
    let(:config) { super().merge({ use_ssm: true }) }

    before do
      allow(ssm_port_forwarding_session).to receive(:wait_for_local_port).and_return(9999)
      allow(ssm_port_forwarding_session).to receive(:close)

      mock_ec2_describe_instances(ec2_client, [{ instance_id: "i-0d9c4bg3f26157a8e" }])
    end

    it "closes any port forwarding sessions" do
      # this should result in an ssm port forwarding session being created
      instances.hosts_for_sshing

      # and this should close that same session
      instances.stop_ssh_port_forwarding_sessions

      expect(ssm_port_forwarding_session).to have_received(:close)
    end
  end
end
