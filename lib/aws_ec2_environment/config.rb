# Holds the details about an application environment composed primarily of EC2 instances, including
#   - what region they're in
#   - the user to use for sshing
#   - how to identify those instances
#   - how to identify the bastion instance to use to connect (if any)
#   - if SSM should be used to connect to the instances
class AwsEc2Environment
  class Config
    attr_reader :env_name,
                :aws_region,
                :ssh_user,
                :instance_filters,
                :bastion_ssh_user,
                :bastion_filters,
                :use_ssm,
                :ssm_host

    # @param [Symbol] env_name
    # @param [Hash] attrs
    def initialize(env_name, attrs)
      @env_name = env_name
      @aws_region = attrs.fetch("aws_region")
      @use_ssm = attrs.fetch("use_ssm", false)
      @ssm_host = attrs.fetch("ssm_host", "127.0.0.1")
      @ssh_user = attrs.fetch("ssh_user")
      @instance_filters = attrs.fetch("filters")

      @bastion_filters, @bastion_ssh_user = fetch_bastion_details(attrs)
    end

    private

    def fetch_bastion_details(attrs)
      bastion_instance = attrs.fetch("bastion_instance", nil)
      bastion_ssh_user = ssh_user

      # if the bastion_instance is a hash, then we need to fetch specific keys
      unless bastion_instance.nil? || bastion_instance.is_a?(Array)
        bastion_ssh_user = bastion_instance.fetch("ssh_user", ssh_user)
        # this is required when using the longhand
        bastion_instance = bastion_instance.fetch("filters")
      end

      [bastion_instance, bastion_ssh_user]
    end
  end
end
