# AwsEc2Environment

A gem that makes it easier to interact with and deploy Ruby projects that are
hosted on EC2 instances in AWS.

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add aws_ec2_environment

If bundler is not being used to manage dependencies, install the gem by
executing:

    $ gem install aws_ec2_environment

## Usage

Use `AwsEc2Environment.from_yaml_file` to create a new representation of your
EC2 environment from a config file:

```ruby
ec2_env = AwsEc2Environment.from_yaml_file("./aws.yml", :production)

# this will ensure that any post-connection cleanup is handled, such as terminating
# any SSM port forwarding sessions that are active
at_exit { ec2_env.stop_ssh_port_forwarding_sessions } if ec2_env.config.use_ssm

# this will return a list of hosts for sshing, handling any pre-connection setup
# such as starting port forwarding sessions for each instance if SSM is enabled.
ec2_env.hosts_for_sshing
```

### Configuration

This is the most basic configuration you can have:

```yaml
production:
  aws_region: ap-southeast-2
  ssh_user: deploy
  filters:
    - name: 'instance-state-name'
      values: ['running']
    - name: 'tag:Name'
      values: ['MyWebsiteProductionAppServerAsg']
```

All the top level properties are required, and the `filters` key holds an array
of filters that are used with the
[`DescribeInstances` API endpoint](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeInstances.html).

### With bastion hosts

You can specify filters for a bastion instance too:

```yaml
production:
  aws_region: ap-southeast-2
  ssh_user: deploy
  filters:
    - name: 'instance-state-name'
      values: ['running']
    - name: 'tag:Name'
      values: ['MyWebsiteProductionAppServerAsg']
  bastion_instance:
    ssh_user: bastion
    filters:
      - name: 'instance-state-name'
        values: ['running']
      - name: 'tag:Name'
        values: ['MyWebsiteProductionBastionAsg']
```

Note that the filters should result in _one_ instance being returned, otherwise
an error will be thrown.

If you use the same user as your application servers, you can pass an array of
filters as the value of the top-level property:

```yaml
production:
  aws_region: ap-southeast-2
  ssh_user: deploy
  filters:
    - name: 'instance-state-name'
      values: ['running']
    - name: 'tag:Name'
      values: ['MyWebsiteProductionAppServerAsg']
  bastion_instance:
    - name: 'instance-state-name'
      values: ['running']
    - name: 'tag:Name'
      values: ['MyWebsiteProductionBastionAsg']
```

#### With SSM

If your instances have the
[SSM Agent](https://docs.aws.amazon.com/systems-manager/latest/userguide/ssm-agent.html)
(preinstalled on some
[AMIs](https://docs.aws.amazon.com/systems-manager/latest/userguide/ami-preinstalled-agent.html)),
you can use SSM to connect directly to instances even if they're in a private
subnet, via port forwarding:

```yaml
production:
  aws_region: ap-southeast-2
  ssh_user: deploy
  ssm_host: 'ec2.#{id}.local.ackama.app'
  use_ssm: true
  filters:
    - name: 'instance-state-name'
      values: ['running']
    - name: 'tag:Name'
      values: ['MyWebsiteProductionAppServerAsg']
```

> This requires the
> [`aws`](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html)
> CLI and
> [`session-manager-plugin`](https://github.com/aws/session-manager-plugin) to
> be installed locally. These both come preinstalled on GitHub Actions runners,
> and are otherwise easy to install manually.
>
> - [Installing `aws` cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
> - [Installing `session-manager-plugin`](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

You can also specify an alternative hostname to use instead of `127.0.0.1` with
the `ssm_host` property - this is useful when working with tools like Capistrano
that only log the host _name_, so this property can let you ensure each instance
can be identified in the logs.

This property should be a host that resolves to `127.0.0.1`, and you can inject
the instance id with `#{id}`.

> Ackama provides `ec2.*.local.ackama.app` for this

### With Capistrano

```ruby
#./ Capfile
# ...
require "aws_ec2_environment"

# ./config/deploy/production.rb
set :rails_env, "production"
set :branch, "production"

ec2_env = AwsEc2Environment.from_yaml_file("./aws.yml", :production)

at_exit { ec2_env.stop_ssh_port_forwarding_sessions } if ec2_env.config.use_ssm

ssh_options = {}

if ec2_env.use_bastion_server?
  ssh_options[:proxy] = Net::SSH::Proxy::Command.new(ec2_env.build_ssh_bastion_proxy_command)
end

set :ssh_options, ssh_options

role(:app, ec2_env.hosts_for_sshing, user: ec2_env.config.ssh_user)
```

### With custom port forwarding

You can also use the `SsmPortForwardingSession` class directly to do port
forwarding, which can be useful for things like custom rake tasks:

```ruby
require "aws_ec2_environment"

task :forward_port, %i[instance_id remote_port local_port] => :environment do |_, args|
  # trap ctl+c to make things a bit nicer (otherwise we'll get an ugly stacktrace)
  # since we expect this to be used to terminate the command
  trap("SIGINT") { exit }

  logger = Logger.new($stdout)

  instance_id = args.fetch(:instance_id)
  remote_port = args.fetch(:remote_port)
  local_port = args.fetch(:local_port, nil)

  session = AwsEc2Environment::SsmPortForwardingSession.new(
    instance_id,
    remote_port,
    local_port:,
    logger:
  )

  at_exit { session.close }

  local_port = session.wait_for_local_port

  local_alias = "ec2.#{instance_id}.local.ackama.app:#{local_port}"
  logger.info "Use #{local_alias} to communicate with port #{remote_port} on #{instance_id}"

  loop { sleep 1 }
end
```

### AWS Authentication and Permissions

Since this gem interacts with AWS, it must be configured with credentials - see
[here](https://docs.aws.amazon.com/sdk-for-ruby/v3/developer-guide/setup-config.html)
for how to do that.

> We recommend using
> [OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
> to authenticate with AWS when running in GitHub Actions.

The credentials must be for an identity that is allowed to perform the
`ec2:DescribeInstances` action. If you're using SSM you must also allow the
`ssm:StartSession` and `ssm:TerminateSession` actions.

Here is a sample IAM policy document that grants these actions conditionally in
accordance with the principle of least privilege:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDescribingInstances",
      "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*"
    },
    {
      "Sid": "AllowStartingPortForwardingSessions",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ssm:*::document/AWS-StartPortForwardingSession"
    },
    {
      "Sid": "AllowStartingNewSessionsOnTaggedEC2Instances",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ec2:*:account-id:instance/*",
      "Condition": {
        "StringEquals": {
          "ssm:resourceTag/Environment": "Production",
          "ssm:resourceTag/Name": "MyWebsiteProductionAppServerAsg"
        }
      }
    },
    {
      "Sid": "AllowTerminatingOwnSessions",
      "Effect": "Allow",
      "Action": "ssm:TerminateSession",
      "Resource": "arn:aws:ssm:*:account-id:session/*",
      "Condition": {
        "StringLike": {
          "ssm:resourceTag/aws:ssmmessages:session-id": "${aws:username}"
        }
      }
    }
  ]
}
```

> Remember to replace "account-id" in the above document with the ID of your AWS
> account!

> If you are using a federated identity (such as GitHub's OpenID Connect
> provider), then you will need to replace `${aws:username}` with
> `${aws:userid}` - see
> [here](https://aws.amazon.com/premiumsupport/knowledge-center/iam-policy-variables-federated/)
> for more.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run
`rake spec` to run the tests. You can also run `bin/console` for an interactive
prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To
release a new version, update the version number in `version.rb`, and then run
`bundle exec rake release`, which will create a git tag for the version, push
git commits and the created tag, and push the `.gem` file to
[rubygems.org](https://rubygems.org).

## Contributing

Contributions are welcome. Please see the
[contribution guidelines](CONTRIBUTING.md) for detailed instructions.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in this project's codebases, issue trackers, chat rooms and
mailing lists is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
