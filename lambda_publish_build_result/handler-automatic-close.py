'''
#       ---------------------------------------------
#   ▪  ▄▄▄▄· • ▌ ▄ ·.     .▄▄ ·  ▄▄▄·      ▄▄▄  ▄▄▄▄▄.▄▄ · 
#   ██ ▐█ ▀█▪·██ ▐███▪    ▐█ ▀. ▐█ ▄█▪     ▀▄ █·•██  ▐█ ▀. 
#   ▐█·▐█▀▀█▄▐█ ▌▐▌▐█·    ▄▀▀▀█▄ ██▀· ▄█▀▄ ▐▀▀▄  ▐█.▪▄▀▀▀█▄
#   ▐█▌██▄▪▐███ ██▌▐█▌    ▐█▄▪▐█▐█▪·•▐█▌.▐▌▐█•█▌ ▐█▌·▐█▄▪▐█
#   ▀▀▀·▀▀▀▀ ▀▀  █▪▀▀▀     ▀▀▀▀ .▀    ▀█▄▀▪.▀  ▀ ▀▀▀  ▀▀▀▀ 
#       ---------------------------------------------
>>> .summary
Lambda function that adds a comment to the Pull Request with the tests results and
automatically close a PR after a failed build

>>> .script_start'''

import boto3
import json
import logging

# Initialize the logger
logger = logging.getLogger()
logger.setLevel(logging.ERROR)

# Initialize the CodeCommit client
codecommit_client = boto3.client("codecommit")


def extract_environment_variables(event):
    """Extract environment variables from the event."""
    logger.debug(f"Extracting environment variables from event: {event}")
    env_vars = event["detail"]["additional-information"]["environment"]["environment-variables"]
    return {item["name"]: item["value"] for item in env_vars}


def determine_comment_content(event, build_status, logs_path, s3_prefix):
    """Determine the content of the comment based on the build status."""
    logger.debug(f"Determining comment content for build status: {build_status}")
    start_time = event["detail"]["additional-information"]["build-start-time"]

    failed_badge = f'https://{s3_prefix}.amazonaws.com/codefactory-{event["region"]}-prod-default-build-badges/failing.svg'
    pass_badge = f'https://{s3_prefix}.amazonaws.com/codefactory-{event["region"]}-prod-default-build-badges/passing.svg'

    if build_status == "IN_PROGRESS":
        return f"**Build started at {start_time}**"
    elif build_status == "FAILED":
        return f'![Failing]({failed_badge} "Failing") - See the [Logs]({logs_path})'
    elif build_status == "SUCCEEDED":
        return f'![Passing]({pass_badge} "Passing") - See the [Logs]({logs_path})'
    elif build_status == "STOPPED":
        return f"STOPPED - See the [Logs]({logs_path})"
    return None


def post_comment(pull_request_id, repository_name, before_commit_id, after_commit_id, content):
    """Post a comment to the pull request."""
    logger.debug(f"Posting comment: {content}")
    try:
        codecommit_client.post_comment_for_pull_request(
            pullRequestId=pull_request_id,
            repositoryName=repository_name,
            beforeCommitId=before_commit_id,
            afterCommitId=after_commit_id,
            content=content,
        )
        logger.info("Comment posted successfully")
    except Exception as e:
        logger.error(f"Error posting comment: {str(e)}")
        raise


def get_revision_id(pull_request_id):
    """Retrieve the latest revision ID for the pull request."""
    try:
        response = codecommit_client.get_pull_request(pullRequestId=pull_request_id)
        revision_id = response["pullRequest"]["revisionId"]
        logger.debug(f"Retrieved revision ID: {revision_id}")
        return revision_id
    except Exception as e:
        logger.error(f"Error retrieving revision ID: {str(e)}")
        raise


def update_approval_state(pull_request_id, approval_status):
    """Update the pull request approval state using the correct revision ID."""
    try:
        revision_id = get_revision_id(pull_request_id)  # Fetch the correct revision ID
        logger.debug(
            f"Updating approval state to {approval_status} for PR {pull_request_id} with revision {revision_id}")

        codecommit_client.update_pull_request_approval_state(
            pullRequestId=pull_request_id,
            revisionId=revision_id,  # Use the correct revision ID
            approvalState=approval_status,
        )

        logger.info(f"Pull request {pull_request_id} approval state updated to {approval_status}")
    except Exception as e:
        logger.error(f"Error updating pull request approval state: {str(e)}")
        raise


def lambda_handler(event, context):
    """Lambda handler function"""
    logger.debug(f"Received event: {json.dumps(event)}")

    try:
        # Extract environment variables
        env_vars = extract_environment_variables(event)
        pull_request_id = env_vars.get("PULL_REQUEST_ID")
        repository_name = env_vars.get("REPOSITORY_NAME")
        before_commit_id = env_vars.get("SOURCE_COMMIT")
        after_commit_id = env_vars.get("DESTINATION_COMMIT")

        build_status = event["detail"]["build-status"]
        logs_path = event["detail"]["additional-information"]["logs"]["deep-link"]
        s3_prefix = "s3-{0}".format(event["region"]) if event["region"] != "us-east-1" else "s3"

        # Determine the content of the comment
        content = determine_comment_content(event, build_status, logs_path, s3_prefix)
        if not content:
            logger.error("Invalid build status, skipping comment posting")
            return {'statusCode': 400, 'body': json.dumps("Invalid build status")}

        # Post the comment to the pull request
        post_comment(pull_request_id, repository_name, before_commit_id, after_commit_id, content)

        # Determine approval state
        approval_status = None
        if build_status == "SUCCEEDED":
            approval_status = "APPROVE"
        else:
            approval_status = "REVOKE"

        if approval_status:
            try:
                update_approval_state(pull_request_id, approval_status)
                return {'statusCode': 200, 'body': {"status": "approved"}}
            except Exception as e:
                return {'statusCode': 500, 'body': json.dumps(f"Error processing pull request: {str(e)}")}

        return {'statusCode': 200, 'body': json.dumps("Comment posted successfully")}

    except Exception as e:
        logger.error(f"Lambda execution failed: {str(e)}")
        return {'statusCode': 500, 'body': json.dumps(f"Lambda execution failed: {str(e)}")}