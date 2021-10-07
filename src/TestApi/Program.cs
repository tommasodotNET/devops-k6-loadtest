var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/fastapi", () => "Hello World!");
// app.MapGet("/fastapi", () =>
// {
//     Thread.Sleep(2000);
//     return "Sorry for the delay... Hello World!";
// });

app.Run();
