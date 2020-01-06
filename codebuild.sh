#!/bin/sh
# Build Script for PureWeb Build Example 

export BUILD_DIR=$CODEBUILD_SRC_DIR/build

# Exit immediately on any error
set -e

# Build linux by default
echo "Building $PROJECT"

# Install javascript packages
npm install

# Build HTML5 libraries
npm run build

# Deploy .zip artifact to S3 bucket
if [ "$UPLOAD_S3" = "true" ]
then
    echo "Publishing artifacts to S3 bucket $S3_BUCKET in region $DEFAULT_REGION_NAME"
    # if build dir exists
    if [ -d "$BUILD_DIR" ]
    then
		# This will empty out the bucket
		aws s3 rm s3://$S3_BUCKET --recursive
		
		# This will upload to the bucket and make the files public
		aws s3 sync $BUILD_DIR s3://$S3_BUCKET --acl public-read
	else
		echo "Could not upload build to $S3_BUCKET"
    fi
fi
