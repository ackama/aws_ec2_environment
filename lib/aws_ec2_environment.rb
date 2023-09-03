require "aws-sdk-ec2"
require "socket"
require "yaml"

class AwsEc2Environment
  class Error < StandardError; end
  class BastionNotExpectedError < Error; end
  class BastionNotFoundError < Error; end
  class EnvironmentConfigNotFound < Error; end

  require_relative "aws_ec2_environment/ssm_port_forwarding_session"
  require_relative "aws_ec2_environment/ci_service"
  require_relative "aws_ec2_environment/config"
  require_relative "aws_ec2_environment/version"

  attr_reader :config

  def self.from_yaml_file(path, env_name)
    config = YAML.safe_load_file(path).fetch(env_name.to_s, nil)

    raise EnvironmentConfigNotFound, "#{path} does not have an environment named \"#{env_name}\"" if config.nil?

    new(AwsEc2Environment::Config.new(env_name, config))
  end

  def initialize(config, logger: Logger.new($stdout))
    @config = config
    @logger = logger
    @ssm_port_forwarding_sessions = []
  end

  # Lists the IDs of the EC2 instances matched by the environment instance filters
  #
  # If an instance does not have a public ip, its private ip will be used instead.
  def ips
    ips = ec2_instances.map { |instance| instance.public_ip_address || instance.private_ip_address }

    log "found the following instances: #{ips.join(", ")}"

    ips
  end

  # Lists the IDs of the EC2 instances matched by the environment instance filters
  def ids
    ids = ec2_instances.map(&:instance_id)

    log "found the following instances: #{ids.join(", ")}"

    ids
  end

  # Lists the hosts to use for sshing into the EC2 instances matched by the environment instance filters.
  #
  # If SSM should be used to connect to the instances, then porting sessions will created.
  def hosts_for_sshing
    return ips unless @config.use_ssm

    log "using SSM to connect to instances"

    reason = ssm_session_reason

    ids.map { |id| "#{@config.ssm_host.gsub("\#{id}", id)}:#{start_ssh_port_forwarding_session(id, reason)}" }
  end

  def use_bastion_server?
    !@config.bastion_filters.nil?
  end

  # Finds the public ip of the bastion instance for this environment.
  #
  # An error will be thrown if any of the following are true:
  #   - no bastion filters have been provided (indicating a bastion should not be used)
  #   - no instances are matched
  #   - multiple instance are matched
  #   - the matched instance does not have a public ip
  def bastion_public_ip
    if @config.bastion_filters.nil?
      raise BastionNotExpectedError, "The #{@config.env_name} environment is not configured with a bastion"
    end

    instances = ec2_describe_instances(@config.bastion_filters)

    if instances.length != 1
      raise(
        BastionNotFoundError,
        "#{instances.length} potential bastion instances were found - " \
        "please ensure your filters are specific enough to only return a single instance"
      )
    end

    ip_address = instances[0].public_ip_address

    if ip_address.nil?
      raise BastionNotFoundError, "a potential bastion instance was found, but it does not have a public ip"
    end

    log "using bastion with ip #{ip_address}"

    ip_address
    []
  end

  # Builds a +ProxyCommand+ that can be used with +ssh+ to connect through the bastion instance,
  # which can also be used with tools like +Capistrano+.
  #
  # Calling this command implies that a bastion server is expected to exist,
  # so an error is thrown if one cannot be found.
  #
  # Usage with +Capistrano+:
  #
  # <code>
  # set :ssh_options, proxy: Net::SSH::Proxy::Command.new(instances.build_ssh_bastion_proxy_command)
  # </code>
  def build_ssh_bastion_proxy_command
    "ssh -o StrictHostKeyChecking=no #{@config.bastion_ssh_user}@#{bastion_public_ip} -W %h:%p"
  end

  def stop_ssh_port_forwarding_sessions
    @ssm_port_forwarding_sessions.each(&:close)
  end

  private

  def start_ssh_port_forwarding_session(instance_id, reason)
    session = AwsEc2Environment::SsmPortForwardingSession.new(instance_id, 22, logger: @logger, reason: reason)

    @ssm_port_forwarding_sessions << session

    session.wait_for_local_port
  end

  def ssm_session_reason
    service = AwsEc2Environment::CiService.detect

    # if we're in a CI service, the build id should make it possible to find
    # the details & logs of this specific run, which will have all the info
    return "#{service[:name]}, build #{service[:build_id]}" unless service.nil?

    # use the hostname if we're not on a CI service, as it's usually a good
    # way to identify what physical machine the SSM session was created on
    hostname = Socket.gethostname

    # knowing the user can generally be a better starting point than the hostname,
    # so include that too if possible (note, "USERNAME" is for Windows)
    username = ENV.fetch("USER", ENV.fetch("USERNAME", "<unknown>"))

    "#{username}@#{hostname}"
  end

  # @return [Aws::EC2::Client]
  def ec2
    @ec2 ||= Aws::EC2::Client.new(region: @config.aws_region)
  end

  def ec2_describe_instances(filters)
    ec2.describe_instances(filters: filters).reservations.flat_map(&:instances)
  end

  def ec2_instances
    ec2_describe_instances(@config.instance_filters)
  end

  def log(msg)
    @logger.info "[#{@config.env_name} #{@config.aws_region}] : #{msg}"
  end
end
