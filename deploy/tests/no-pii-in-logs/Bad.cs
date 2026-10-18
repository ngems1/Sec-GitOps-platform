// Lines the guard must catch (deploy/tests/no-pii-in-logs.sh).
Console.WriteLine($"GetCartAsync called with userId={userId}");
CartLog.Info($"GetCartAsync called for userId={userId}");
