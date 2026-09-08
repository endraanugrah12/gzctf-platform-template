using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Diagnostics;
using GZCTF.Services.Container;

using var listener = new TcpListener(IPAddress.Loopback, 0);
listener.Start();
var port = ((IPEndPoint)listener.LocalEndpoint).Port;
var container = new GZCTF.Models.Data.Container { IP = "127.0.0.1", Port = port };
if (!await ContainerReadiness.CheckAsync(container, false, default)) throw new Exception("Listening service should be ready");
listener.Stop();
if (await ContainerReadiness.CheckAsync(container, false, default)) throw new Exception("Stopped service must not be ready");
if (await ContainerReadiness.CheckAsync(container, true, default)) throw new Exception("Missing HTTPS route must not be ready");
using var canceled = new CancellationTokenSource();
canceled.Cancel();
if (await ContainerReadiness.CheckAsync(container, false, canceled.Token)) throw new Exception("Canceled check must not be ready");
Console.WriteLine("PASS: listening TCP, stopped TCP, missing HTTPS route, canceled check");

// Run in the disposable SDK container: trust a temporary localhost certificate
// there so the production probe's normal TLS validation remains enabled.
using var key = RSA.Create(2048);
var request = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
var names = new SubjectAlternativeNameBuilder();
names.AddDnsName("localhost");
request.CertificateExtensions.Add(names.Build());
request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddDays(1));
File.WriteAllText("/usr/local/share/ca-certificates/gzctf-readiness-test.crt", certificate.ExportCertificatePem());
using var trust = Process.Start(new ProcessStartInfo("update-ca-certificates") { RedirectStandardOutput = true });
await trust.WaitForExitAsync();
if (trust.ExitCode != 0) throw new Exception("Could not trust the isolated test certificate");
container.PublicIP = "localhost";
foreach (var status in new[] { 200, 302, 401, 403, 404, 503 })
{
    using var https = new TcpListener(IPAddress.Loopback, 443);
    https.Start();
    var serve = Task.Run(async () =>
    {
        using var connection = await https.AcceptTcpClientAsync();
        using var stream = new SslStream(connection.GetStream());
        await stream.AuthenticateAsServerAsync(certificate);
        var buffer = new byte[4096];
        await stream.ReadAsync(buffer);
        await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
    });
    var ready = await ContainerReadiness.CheckAsync(container, true, default);
    await serve.WaitAsync(TimeSpan.FromSeconds(3));
    if (ready != (status < 404)) throw new Exception($"Unexpected readiness for HTTP {status}");
}
Console.WriteLine("PASS: HTTPS 200/302/401/403 ready; HTTPS 404/503 not ready");

namespace GZCTF.Models.Data
{
    public class Container
    {
        public string IP { get; set; }
        public int Port { get; set; }
        public string PublicIP { get; set; }
    }
}
