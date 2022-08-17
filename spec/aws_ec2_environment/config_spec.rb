require "json"

RSpec.describe AwsEc2Environment::Config do
  subject(:ec2_env) { described_class.new(:production, JSON.parse(attrs.to_json)) }

  let(:attrs) do
    {
      aws_region: "ap-southeast-2",
      ssh_user: "ubuntu",
      filters: [
        { name: "instance-state-name", values: ["running"] },
        { name: "tag:Name", values: ["ProductionAppServer"] }
      ]
    }
  end

  it "sets the aws_region" do
    expect(ec2_env.aws_region).to eql "ap-southeast-2"
  end

  it "sets the ssh_user" do
    expect(ec2_env.ssh_user).to eql "ubuntu"
  end

  it "sets the instance_filters" do
    expect(ec2_env.instance_filters).to eql [
      { "name" => "instance-state-name", "values" => ["running"] },
      { "name" => "tag:Name", "values" => ["ProductionAppServer"] }
    ]
  end

  it "does not set the bastion_filters" do
    expect(ec2_env.bastion_filters).to be_nil
  end

  it "sets use_ssm to false by default" do
    expect(ec2_env.use_ssm).to be false
  end

  context "when use_ssm is present" do
    let(:attrs) { super().merge({ use_ssm: true }) }

    it "sets the value accordingly" do
      expect(ec2_env.use_ssm).to be true
    end
  end

  context "when bastion_instance is present" do
    context "when bastion_instance is an array" do
      let(:attrs) do
        super().merge(
          {
            bastion_instance: [
              { name: "instance-state-name", values: ["running"] },
              { name: "tag:Name", values: ["ProductionBastion"] }
            ]
          }
        )
      end

      it "uses the values as the bastion_filters" do
        expect(ec2_env.bastion_filters).to eql [
          { "name" => "instance-state-name", "values" => ["running"] },
          { "name" => "tag:Name", "values" => ["ProductionBastion"] }
        ]
      end

      it "uses the default ssh_user" do
        expect(ec2_env.bastion_ssh_user).to eql "ubuntu"
      end
    end

    context "when bastion_instance is an object" do
      let(:attrs) do
        super().merge(
          {
            bastion_instance: {
              ssh_user: "bastion",
              filters: [
                { name: "instance-state-name", values: ["running"] },
                { name: "tag:Name", values: ["ProductionBastion"] }
              ]
            }
          }
        )
      end

      it "lets you use a different ssh_user" do
        expect(ec2_env.bastion_ssh_user).to eql "bastion"
      end

      it "correctly sets bastion_filters" do
        expect(ec2_env.bastion_filters).to eql [
          { "name" => "instance-state-name", "values" => ["running"] },
          { "name" => "tag:Name", "values" => ["ProductionBastion"] }
        ]
      end
    end
  end
end
