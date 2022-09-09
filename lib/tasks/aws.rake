require "aws_ec2_environment"
require "aws-sdk-ec2"

namespace :aws do # rubocop:disable Metrics/BlockLength
  namespace :ec2 do # rubocop:disable Metrics/BlockLength
    desc "Lists all the running EC2 instances in the configured account & region"
    task list_running_instances: :environment do # rubocop:disable Metrics/BlockLength
      ec2 = Aws::EC2::Client.new

      instances = ec2.describe_instances(
        filters: [{ name: "instance-state-name", values: ["running"] }]
      ).reservations.flat_map do |reservations|
        reservations[:instances].map do |instance|
          {
            id: instance.instance_id,
            type: instance.instance_type,
            launch_time: instance.launch_time.to_s,
            environment: instance.tags.find { |t| t.key == "Environment" }&.value || "<unknown>",
            name: instance.tags.find { |t| t.key == "Name" }&.value || "<unknown>",
            public_ip_address: instance.public_ip_address || "--",
            private_ip_address: instance.private_ip_address || "--"
          }
        end
      end

      instances = instances.sort_by { |instance| [instance[:environment], instance[:name], instance[:id]] }

      col_labels = {
        environment: "Environment",
        name: "Name",
        id: "Instance ID",
        type: "Type",
        public_ip_address: "Public IP",
        private_ip_address: "Private IP",
        launch_time: "Launch Time"
      }
      columns = col_labels.map do |key, label|
        all = ["", label, ""] + instances.map { |instance| instance[key] }
        max = all.max_by(&:length).length
        divider = "-" * max

        all[0] = divider
        all[2] = divider
        all << divider

        all.map { |str| str.ljust(max) }
      end

      rows = columns.transpose

      rows.each_with_index do |row, i|
        if i == 0 || i == 2 || (i == rows.length - 1)
          puts "+-#{row.join("-+-")}-+"
          next
        end

        puts "| #{row.join(" | ")} |"
      end
    end
  end

  namespace :ssm do
    desc "Starts a port forwarding session to the given instance, even if the instance is in a private subnet"
    task :forward_port, %i[instance_id remote_port local_port remote_host] => :environment do |_, args|
      # trap ctl+c to make things a bit nicer (otherwise we'll get an ugly stacktrace)
      # since we expect this to be used to terminate the command
      trap("SIGINT") { exit }

      logger = Logger.new($stdout)

      instance_id = args.fetch(:instance_id)
      remote_port = args.fetch(:remote_port)
      remote_host = args.fetch(:remote_host, nil)
      local_port = args.fetch(:local_port, nil)

      session = AwsEc2Environment::SsmPortForwardingSession.new(
        instance_id,
        remote_port,
        remote_host:,
        local_port:,
        logger:
      )

      at_exit { session.close }

      local_port = session.wait_for_local_port

      host = remote_host || instance_id
      via = ""
      via = " via #{instance_id}" unless remote_host.nil?

      logger.info "Use port #{local_port} to communicate #{host} on with port #{remote_port}#{via}"

      loop { sleep 1 }
    end
  end
end
