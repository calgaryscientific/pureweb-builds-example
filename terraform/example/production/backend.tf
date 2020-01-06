# this is the backend configuration where terraform will store the lock file for the specific build
# the only piece that needs to be modified will be the key value

terraform {
  backend "s3" {
	 # you must change the key value to describe your build
     key = "production/example"
     region = "us-west-2"
     bucket = "pureweb-builds-tfstate-file-storage"
     dynamodb_table = "pureweb-builds-terraform-state-locking"
     encrypt = true
  }
}
