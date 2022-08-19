require "json"

RSpec.describe AwsEc2Environment::CiService do
  describe ".detect" do
    context "when running in a CI service" do
      before { stub_const("ENV", { "GITHUB_ACTIONS" => "", "GITHUB_RUN_ID" => "1234" }) }

      it "returns the service name and build id" do
        service = described_class.detect

        expect(service).to eql({ name: "GitHub Actions", build_id: "1234" })
      end
    end

    context "when not running in a CI service" do
      before { stub_const("ENV", {}) }

      it "returns nil" do
        expect(described_class.detect).to be_nil
      end
    end
  end
end
