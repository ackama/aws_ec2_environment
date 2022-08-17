class AwsEc2Environment
  class CiService # rubocop:disable Metrics/ClassLength
    CI_SERVICES = [
      {
        name: "AppVeyor",
        detect: "APPVEYOR",
        build_id_var: "APPVEYOR_BUILD_NUMBER"
      },
      {
        name: "Azure Pipelines",
        detect: "BUILD_BUILDURI",
        build_id_var: "BUILD_BUILDNUMBER"
      },
      {
        name: "Bamboo",
        detect: "bamboo_agentId",
        build_id_var: "bamboo_buildNumber"
      },
      {
        name: "BitBucket Pipelines",
        detect: "BITBUCKET_BUILD_NUMBER",
        build_id_var: "BITBUCKET_BUILD_NUMBER"
      },
      {
        name: "Buddy",
        detect: "BUDDY_WORKSPACE_ID",
        build_id_var: "BUDDY_EXECUTION_ID"
      },
      {
        name: "Buildkite",
        detect: "BUILDKITE",
        build_id_var: "BUILDKITE_BUILD_NUMBER"
      },
      {
        name: "CircleCI",
        detect: "CIRCLECI",
        build_id_var: "CIRCLE_BUILD_NUM"
      },
      {
        name: "Cirrus",
        detect: "CIRRUS_CI",
        build_id_var: "CIRRUS_BUILD_ID"
      },
      {
        name: "CodeBuild",
        detect: "CODEBUILD_BUILD_ID",
        build_id_var: "CODEBUILD_BUILD_ID"
      },
      {
        name: "Codefresh",
        detect: "CF_BUILD_ID",
        build_id_var: "CF_BUILD_ID"
      },
      {
        name: "CodeShip",
        detect: -> { ENV.fetch("CI_NAME", "") == "codeship" },
        build_id_var: "CI_BUILD_NUMBER"
      },
      {
        name: "Drone",
        detect: "DRONE",
        build_id_var: "DRONE_BUILD_NUMBER"
      },
      {
        name: "GitHub Actions",
        detect: "GITHUB_ACTIONS",
        build_id_var: "GITHUB_RUN_ID"
      },
      {
        name: "GitLab",
        detect: "GITLAB_CI",
        build_id_var: "CI_PIPELINE_ID"
      },
      {
        name: "Jenkins",
        detect: "JENKINS_URL",
        build_id_var: "BUILD_NUMBER"
      },
      {
        name: "JetBrains Spaces",
        detect: "JB_SPACE_EXECUTION_NUMBER",
        build_id_var: "JB_SPACE_EXECUTION_NUMBER"
      },
      {
        name: "Puppet",
        detect: "DISTELLI_APPNAME",
        build_id_var: "DISTELLI_BUILDNUM"
      },
      {
        name: "Scrutinizer",
        detect: "SCRUTINIZER",
        build_id_var: "SCRUTINIZER_INSPECTION_UUID"
      },
      {
        name: "Semaphore",
        detect: "SEMAPHORE",
        build_id_var: "SEMAPHORE_JOB_ID"
      },
      {
        name: "Shippable",
        detect: "SHIPPABLE",
        build_id_var: "BUILD_NUMBER"
      },
      {
        name: "TeamCity",
        detect: "TEAMCITY_VERSION",
        build_id_var: "BUILD_NUMBER"
      },
      {
        name: "Travis",
        detect: "TRAVIS",
        build_id_var: "TRAVIS_BUILD_NUMBER"
      },
      {
        name: "Vela",
        detect: "VELA",
        build_id_var: "VELA_BUILD_NUMBER"
      },
      {
        name: "Wercker",
        detect: "WERCKER_MAIN_PIPELINE_STARTED",
        build_id_var: "WERCKER_MAIN_PIPELINE_STARTED"
      },
      {
        name: "Woodpecker",
        detect: -> { ENV.fetch("CI", "") == "woodpecker" },
        build_id_var: "CI_BUILD_NUMBER"
      }
    ].freeze

    # Attempts to determine if the current process is running on a CI service,
    # and if so returns the name of the service and the id of the current build
    # which generally can be used to find the details and logs for this build.
    def self.detect
      service = CI_SERVICES.find do |details|
        if details[:detect].is_a? String
          ENV.key? details[:detect]
        else
          details[:detect].call
        end
      end

      return nil if service.nil?

      {
        name: service[:name],
        build_id: ENV.fetch(service[:build_id_var])
      }
    end
  end
end
