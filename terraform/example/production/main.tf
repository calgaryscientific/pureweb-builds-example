provider "aws" {
  region = "us-west-2"
}

/*---------------------------------------------------------------------*/
# this resource is used for the example repository you should really be adding 
# this resource to the pureweb-builds /terraform/registry/terraform.tfvars file

resource "aws_s3_bucket" "s3_deploy_bucket" {
    bucket = "example.pureweb.io"
	acl    = "public-read"
	force_destroy = "true"
}
/*---------------------------------------------------------------------*/

# if you would like to build a docker container and push to ecr you must create an ecr resource
resource "aws_ecr_repository" "ecr_code_build" {
    name = "pw5-example" 
}

module "build" {
    source              = "../../modules/build"
	namespace           = "pw5"

	# whatever is defined as the stage will be passed forward as an environment variable STAGE
    stage               = "production"

	name                = "example"

	# be sure to create a dockerfile into pureweb-builds repository under code_build_agents
	# and add the ecr entry to the registry terraform.tvars file and images.yml
	# this example repository does not need a build image and we will define a default AWS build container
	# check out http://docs.aws.amazon.com/codebuild/latest/userguide/build-env-ref.html for availible inclusions
	# build_image         = "630322998121.dkr.ecr.us-west-2.amazonaws.com/pw5-custom-example-build-container"

	build_image 		= "aws/codebuild/standard:2.0"

	# use CODEBUILD if your building one of AWS prebuilt build containers
	# default value
	# image_pull_credentials_type = "SERVICE_ROLE"

	image_pull_credentials_type = "CODEBUILD"

	# default values
	# build_compute_type  = "BUILD_GENERAL1_SMALL"
    # build_timeout       = 60

	source_location 	= "https://github.com/calgaryscientific/pureweb-builds-example.git"
	
	# default value
	# cache_enabled	  = true

	# if you would like to build a docker container within this build container you must toggle this flag to true
	privileged_mode   = true 

	# specify what branch you want this codebuild to watch
	# default value
	# branch_hook	  = "master"

	# for the specified branch you can trigger a build on a specifed action the options include "PUSH, PULL_REQUEST_MERGED, PULL_REQUEST_CREATED, PULL_REQUEST_UPDATED, PULL_REQUEST_REOPENED"
	# default value
	# event_triggers  = "PUSH, PULL_REQUEST_MERGED"

	# to add additional environment variables for use in this build container use the array syntax defined below
    # environment_variables = [{
	#	name = "COMPILER"
	#	value = "clang"
	# }, {
	# 	name = "ANOTHER"
	#	value = "another"
	# }]
}
