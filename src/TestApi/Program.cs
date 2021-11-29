var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/fastapi", () => "Hello World!");

app.Run();
