package bad

// Lines the guard must catch (deploy/tests/no-pii-in-logs.sh), one per pattern family.
func f() {
	log.Infof("order confirmation email sent to %q", req.Email)
	log.Warnf("[PlaceOrder] rejected for user_id=%q", req.UserId)
	log = log.WithField("session", v)
	log.WithField("ua", r.UserAgent()).Info("request")
	log.Infof("query %s", r.URL.RawQuery)
}
