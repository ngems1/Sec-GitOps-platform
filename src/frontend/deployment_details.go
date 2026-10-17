package main

import (
	"net/http"
	"os"
	"time"

	"cloud.google.com/go/compute/metadata"
	"github.com/sirupsen/logrus"
)

var deploymentDetailsMap map[string]string
var log *logrus.Logger

func init() {
	initializeLogger()
	// Use a goroutine to ensure loadDeploymentDetails()'s GCP API
	// calls don't block non-GCP deployments. See issue #685.
	go loadDeploymentDetails()
}

func initializeLogger() {
	log = logrus.New()
	log.Level = logrus.InfoLevel // no per-request Debug lines (ADR 0011)
	log.Formatter = &logrus.JSONFormatter{
		FieldMap: logrus.FieldMap{
			logrus.FieldKeyTime:  "timestamp",
			logrus.FieldKeyLevel: "severity",
			logrus.FieldKeyMsg:   "message",
		},
		TimestampFormat: time.RFC3339Nano,
	}
	log.Out = os.Stdout
	log.AddHook(traceLogHook{}) // trace_id / span_id on lines logged with a context (logtrace.go)
}

func loadDeploymentDetails() {
	deploymentDetailsMap = make(map[string]string)
	// Week 3: the release shown in the footer (the commit SHA the image was built from,
	// baked in by the Dockerfile). Makes a deployment or a rollback visible in the shop.
	if v := os.Getenv("APP_VERSION"); v != "" {
		deploymentDetailsMap["VERSION"] = v
	}
	var metaServerClient = metadata.NewClient(&http.Client{})

	podHostname, err := os.Hostname()
	if err != nil {
		log.Error("Failed to fetch the hostname for the Pod", err)
	}

	podCluster, err := metaServerClient.InstanceAttributeValue("cluster-name")
	if err != nil {
		log.Error("Failed to fetch the name of the cluster in which the pod is running", err)
	}

	podZone, err := metaServerClient.Zone()
	if err != nil {
		log.Error("Failed to fetch the Zone of the node where the pod is scheduled", err)
	}

	deploymentDetailsMap["HOSTNAME"] = podHostname
	deploymentDetailsMap["CLUSTERNAME"] = podCluster
	deploymentDetailsMap["ZONE"] = podZone

	log.WithFields(logrus.Fields{
		"cluster":  podCluster,
		"zone":     podZone,
		"hostname": podHostname,
	}).Debug("Loaded deployment details")
}
