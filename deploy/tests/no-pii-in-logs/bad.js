// Lines the guard must catch (deploy/tests/no-pii-in-logs.sh).
logger.info(`PaymentService#Charge invoked with request ${JSON.stringify(call.request)}`);
logger.info(`Transaction processed ending ${cardNumber.substr(-4)}`);
