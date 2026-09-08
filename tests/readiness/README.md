Run from the repository root in a disposable container (the HTTPS test trusts a temporary localhost certificate inside that container):

```sh
docker run --rm -v "$PWD:/workspace" -w /workspace/tests/readiness mcr.microsoft.com/dotnet/sdk:10.0 dotnet run
python3 -m unittest discover -s compose/challenge-proxy -p 'test_*.py' -v
```

The C# harness compiles the production readiness probe and tests real local TCP and TLS listeners. It does not contact challenge instances. The minimal Container stand-in keeps the test independent of the full application's database and frontend dependencies.
