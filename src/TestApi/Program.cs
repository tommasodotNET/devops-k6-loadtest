var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/fastapi", () => "Hello World!");
app.MapGet("/slowapi", () =>
{
    Thread.Sleep(1);
    return "Sorry for the delay... Hello World!";
});

app.Run();
