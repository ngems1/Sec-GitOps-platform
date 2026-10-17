#!/usr/bin/python
#
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from concurrent import futures
import argparse
import os
import sys
import time
import grpc
import traceback
from jinja2 import Environment, FileSystemLoader, select_autoescape, TemplateError
from google.api_core.exceptions import GoogleAPICallError
from google.auth.exceptions import DefaultCredentialsError

import demo_pb2
import demo_pb2_grpc
from grpc_health.v1 import health_pb2
from grpc_health.v1 import health_pb2_grpc

from tracing import start_tracing

import googlecloudprofiler

from logger import getJSONLogger
logger = getJSONLogger('emailservice-server')

# Week 3: notification consumer (notification-q -> email + DynamoDB log). On when
# NOTIFICATION_QUEUE_URL and NOTIFICATIONS_TABLE are set; see notifications.py.
NOTIFICATION_QUEUE_URL = os.environ.get('NOTIFICATION_QUEUE_URL', '')
NOTIFICATIONS_TABLE = os.environ.get('NOTIFICATIONS_TABLE', '')
consumer = None

# Loads confirmation email template from file
env = Environment(
    loader=FileSystemLoader('templates'),
    autoescape=select_autoescape(['html', 'xml'])
)
template = env.get_template('confirmation.html')

class BaseEmailService(demo_pb2_grpc.EmailServiceServicer):
  def Check(self, request, context):
    # Week 3: not ready while the notification consumer has stopped polling.
    if consumer is not None and not consumer.healthy():
      return health_pb2.HealthCheckResponse(
        status=health_pb2.HealthCheckResponse.NOT_SERVING)
    return health_pb2.HealthCheckResponse(
      status=health_pb2.HealthCheckResponse.SERVING)
  
  def Watch(self, request, context):
    return health_pb2.HealthCheckResponse(
      status=health_pb2.HealthCheckResponse.UNIMPLEMENTED)

class EmailService(BaseEmailService):
  def __init__(self):
    raise Exception('cloud mail client not implemented')
    super().__init__()

  @staticmethod
  def send_email(client, email_address, content):
    response = client.send_message(
      sender = client.sender_path(project_id, region, sender_id),
      envelope_from_authority = '',
      header_from_authority = '',
      envelope_from_address = from_address,
      simple_message = {
        "from": {
          "address_spec": from_address,
        },
        "to": [{
          "address_spec": email_address
        }],
        "subject": "Your Confirmation Email",
        "html_body": content
      }
    )
    logger.info("Message sent: {}".format(response.rfc822_message_id))

  def SendOrderConfirmation(self, request, context):
    email = request.email
    order = request.order

    try:
      confirmation = template.render(order = order)
    except TemplateError as err:
      context.set_details("An error occurred when preparing the confirmation mail.")
      logger.error(err.message)
      context.set_code(grpc.StatusCode.INTERNAL)
      return demo_pb2.Empty()

    try:
      EmailService.send_email(self.client, email, confirmation)
    except GoogleAPICallError as err:
      context.set_details("An error occurred when sending the email.")
      print(err.message)
      context.set_code(grpc.StatusCode.INTERNAL)
      return demo_pb2.Empty()

    return demo_pb2.Empty()

class DummyEmailService(BaseEmailService):
  def SendOrderConfirmation(self, request, context):
    logger.info('A request to send order confirmation email to {} has been received.'.format(request.email))
    return demo_pb2.Empty()

class HealthCheck():
  def Check(self, request, context):
    return health_pb2.HealthCheckResponse(
      status=health_pb2.HealthCheckResponse.SERVING)

def start_notification_consumer():
  """Week 3: consume notification-q in a background thread (AWS creds from EKS Pod Identity)."""
  global consumer
  if not (NOTIFICATION_QUEUE_URL and NOTIFICATIONS_TABLE):
    logger.info('notification consumer disabled (NOTIFICATION_QUEUE_URL / NOTIFICATIONS_TABLE not set)')
    return
  import threading
  import boto3
  import notifications
  session = boto3.session.Session(region_name=os.environ.get('AWS_REGION', 'us-east-1'))
  # Optional: also post each order outcome to Slack (webhook from a Kubernetes Secret).
  slack = None
  webhook = os.environ.get('SLACK_ORDERS_WEBHOOK_URL', '')
  if webhook:
    slack = notifications.SlackNotifier(webhook, os.environ.get('ENVIRONMENT', ''), logger)
    logger.info('order notifications also posted to Slack')
  # Optional: real emails through Amazon SES to the verified (sandbox) recipients.
  ses = None
  ses_from = os.environ.get('SES_FROM_ADDRESS', '')
  ses_to = [a for a in os.environ.get('SES_ALLOWED_RECIPIENTS', '').split(',') if a.strip()]
  if ses_from and ses_to:
    ses = notifications.SesSender(session.client('sesv2'), ses_from, ses_to)
    logger.info('real emails through SES', extra={'from': ses_from, 'recipients': len(ses_to)})
  consumer = notifications.Consumer(
    session.client('sqs'), NOTIFICATION_QUEUE_URL,
    notifications.NotificationLog(session.client('dynamodb'), NOTIFICATIONS_TABLE), logger, slack, ses)
  consumer.last_poll = time.time()  # healthy while the first long poll starts
  threading.Thread(target=consumer.run, name='notification-consumer', daemon=True).start()

def start(dummy_mode):
  server = grpc.server(futures.ThreadPoolExecutor(max_workers=10),)
  service = None
  if dummy_mode:
    service = DummyEmailService()
  else:
    raise Exception('non-dummy mode not implemented yet')

  demo_pb2_grpc.add_EmailServiceServicer_to_server(service, server)
  health_pb2_grpc.add_HealthServicer_to_server(service, server)

  port = os.environ.get('PORT', "8080")
  logger.info("listening on port: "+port)
  server.add_insecure_port('[::]:'+port)
  server.start()
  start_notification_consumer()
  try:
    while True:
      time.sleep(3600)
  except KeyboardInterrupt:
    if consumer is not None:
      consumer.stopping = True
    server.stop(0)

def initStackdriverProfiling():
  project_id = None
  try:
    project_id = os.environ["GCP_PROJECT_ID"]
  except KeyError:
    # Environment variable not set
    pass

  for retry in range(1,4):
    try:
      if project_id:
        googlecloudprofiler.start(service='email_server', service_version='1.0.0', verbose=0, project_id=project_id)
      else:
        googlecloudprofiler.start(service='email_server', service_version='1.0.0', verbose=0)
      logger.info("Successfully started Stackdriver Profiler.")
      return
    except (BaseException) as exc:
      logger.info("Unable to start Stackdriver Profiler Python agent. " + str(exc))
      if (retry < 4):
        logger.info("Sleeping %d to retry initializing Stackdriver Profiler"%(retry*10))
        time.sleep (1)
      else:
        logger.warning("Could not initialize Stackdriver Profiler after retrying, giving up")
  return


if __name__ == '__main__':
  logger.info('starting the email service in dummy mode.')

  # Profiler
  try:
    if "DISABLE_PROFILER" in os.environ:
      raise KeyError()
    else:
      logger.info("Profiler enabled.")
      initStackdriverProfiling()
  except KeyError:
      logger.info("Profiler disabled.")

  # Tracing before the gRPC server exists: server spans whenever ENABLE_TRACING=1 (tracing.py, ADR 0010).
  start_tracing("emailservice", logger)
  
  start(dummy_mode = True)
