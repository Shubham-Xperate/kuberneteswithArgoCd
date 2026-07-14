# 02 — The .NET 8 Web API Backend

## The hosting model: why `Program.cs` and no `Startup.cs`

Older ASP.NET Core tutorials show two files: `Program.cs`, a tiny bootstrapper that just called `CreateHostBuilder(args).Build().Run()`, and `Startup.cs`, which held two methods — `ConfigureServices` (register things into the DI container) and `Configure` (build the HTTP request pipeline with middleware). This project's `backend/src/ECommerce.Api/Program.cs` uses the newer **minimal hosting model**, introduced in .NET 6 and used unchanged here in .NET 8: there is only one file, and it runs top-to-bottom as a script. The split still conceptually exists — you'll notice the file has an "everything before `builder.Build()`" half and an "everything after" half — but it's no longer forced into two separate classes/methods. The reason this model replaced `Startup.cs` is simply less ceremony: for the vast majority of APIs, the indirection of two classes calling into each other added boilerplate without adding clarity. Here's the actual shape from `Program.cs`:

```csharp
var builder = WebApplication.CreateBuilder(args);

// ---- everything from here down is "ConfigureServices" in spirit ----
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(builder.Configuration.GetConnectionString("DefaultConnection")));
// ... AddIdentity, AddAuthentication, AddCors, AddControllers, AddSwaggerGen, AddHealthChecks ...

var app = builder.Build();

// ---- everything from here down is "Configure" in spirit ----
app.UseCors(CorsPolicyName);
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapHealthChecks("/health", ...);
app.MapHealthChecks("/health/live", ...);

app.Run();
```

`WebApplication.CreateBuilder(args)` does a lot of implicit setup you'd otherwise write by hand: it wires up configuration sources in a specific priority order (`appsettings.json`, then `appsettings.{Environment}.json`, then environment variables, then command-line args — later sources win), sets up the default logging providers, and prepares an empty `IServiceCollection` (`builder.Services`) you register things into. Everything between that call and `builder.Build()` is *registration only* — you are telling the framework "here are the ingredients," but nothing runs yet. `builder.Build()` is the moment those registrations get compiled into an actual, queryable dependency injection container and wrapped in a runnable `WebApplication` object. Everything after that point is *pipeline configuration and startup logic* — middleware ordering, one-time startup work like role seeding, and finally `app.Run()`, which blocks the thread and starts actually listening for HTTP requests.

## Dependency injection: why services are registered, not `new`'d

Every line like `builder.Services.AddDbContext<AppDbContext>(...)` or `builder.Services.AddScoped<IJwtTokenService, JwtTokenService>()` is populating ASP.NET Core's built-in **dependency injection (DI) container**. The idea DI solves: instead of a class reaching out and constructing its own dependencies (`var db = new AppDbContext(...)` scattered everywhere), a class simply *declares* what it needs in its constructor, and a central container is responsible for constructing and supplying those dependencies wherever they're asked for. Look at `AuthController`:

```csharp
public AuthController(
    UserManager<ApplicationUser> userManager,
    SignInManager<ApplicationUser> signInManager,
    IJwtTokenService jwtTokenService)
{
    _userManager = userManager;
    _signInManager = signInManager;
    _jwtTokenService = jwtTokenService;
}
```

`AuthController` never constructs a `JwtTokenService` itself — it only declares a dependency on the `IJwtTokenService` *interface*. When ASP.NET Core needs to create an `AuthController` to handle an incoming request, it looks at the constructor, sees it needs an `IJwtTokenService`, checks the DI container's registrations, finds `builder.Services.AddScoped<IJwtTokenService, JwtTokenService>()` from `Program.cs`, and supplies a `JwtTokenService` instance automatically. This buys two concrete things: testability (a unit test can supply a fake `IJwtTokenService` without touching the real implementation) and centralized lifetime management. That second point matters more than it sounds: `AddScoped` means "create one instance per incoming HTTP request, and reuse that same instance for anything else in the same request that also asks for it" — as opposed to `AddSingleton` (one instance for the entire application's lifetime) or `AddTransient` (a brand-new instance every single time it's requested). `AppDbContext` and `IJwtTokenService` are both scoped here because a `DbContext` in particular is not thread-safe and is designed to track one unit-of-work per request; sharing one across concurrent requests would cause data corruption, and creating a new one per class-instance-within-a-request would break EF Core's change tracking.

## EF Core and the `DbContext`: what it actually is

Entity Framework Core (EF Core) is the project's **ORM** (object-relational mapper) — a layer that translates between C# objects (`Product`, `Order`, `Category`) and rows in a SQL Server database, so application code manipulates plain objects instead of writing raw SQL by hand for every query. The center of that layer is `AppDbContext` in `backend/src/ECommerce.Api/Data/AppDbContext.cs`. A `DbContext` is best understood as a *session* with the database: it tracks which objects you've loaded, what's changed on them since loading, and translates LINQ queries like `_context.Products.Where(p => p.CategoryId == categoryId)` into actual SQL, only when you actually enumerate the results (this is called *deferred execution*). It also batches up pending inserts/updates/deletes and only sends them to the database when you call `SaveChangesAsync()` — that's the "unit of work" pattern: everything you do to tracked objects during a scoped `DbContext`'s lifetime becomes one atomic-ish batch of SQL.

This project's `AppDbContext` inherits from `IdentityDbContext<ApplicationUser>` rather than plain `DbContext`:

```csharp
public class AppDbContext : IdentityDbContext<ApplicationUser>
{
    public DbSet<Category> Categories => Set<Category>();
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Order> Orders => Set<Order>();
    public DbSet<OrderItem> OrderItems => Set<OrderItem>();
    ...
}
```

`IdentityDbContext<ApplicationUser>` is ASP.NET Core Identity's own base class, and inheriting from it automatically brings in the standard Identity tables (`AspNetUsers`, `AspNetRoles`, `AspNetUserRoles`, etc.) alongside this project's own domain tables — one database, one `DbContext`, one migration history, covering both "who can log in" and "what products exist."

## Fluent API: configuring the model in code, not attributes

`OnModelCreating` is where the shape of the database schema is described explicitly, using what's called the **Fluent API** (a fluent, chainable configuration syntax, as opposed to sprinkling `[Required]`/`[MaxLength]` data-annotation attributes directly on model classes). This project chooses Fluent API specifically so the plain C# model classes (`Product`, `Category`, `Order`) stay free of persistence-specific decoration, and so relationships and constraints that don't map cleanly to a single attribute live in one readable place. A representative example from `AppDbContext.cs`:

```csharp
builder.Entity<Order>(entity =>
{
    entity.Property(o => o.TotalAmount).HasPrecision(18, 2);

    // Enum stored as its string name for readability in the database
    entity.Property(o => o.Status)
        .HasConversion<string>()
        .HasMaxLength(20);

    entity.HasMany(o => o.OrderItems)
        .WithOne(oi => oi.Order)
        .HasForeignKey(oi => oi.OrderId)
        .OnDelete(DeleteBehavior.Cascade);
});
```

`HasPrecision(18, 2)` tells SQL Server exactly how to store a `decimal` (18 total digits, 2 after the decimal point) — money values need this to avoid silent rounding surprises. `HasConversion<string>()` on the `Status` enum is a deliberate operational choice: by default EF Core stores enums as their underlying integer, so a database row would show `0` instead of `"Pending"`; converting to string trades a few bytes of storage for being able to read and debug order status directly in SQL Server Management Studio without a lookup table in your head. `HasForeignKey(...).OnDelete(DeleteBehavior.Cascade)` configures what happens to `OrderItem` rows when their parent `Order` is deleted — cascade means they're deleted too, which makes sense because an order item has no meaning without its order. Contrast that with the `Category`→`Product` relationship a few lines up, which uses `DeleteBehavior.Restrict`: SQL Server will *refuse* to delete a category that still has products pointing at it, protecting against accidentally orphaning products.

## Migrations: why you never hand-edit a production schema

A **migration** is a generated C# file (found here under `backend/src/ECommerce.Api/Migrations/`, e.g. `20240101000000_InitialCreate.cs`) that encodes the exact sequence of SQL DDL operations (`CREATE TABLE`, `ADD COLUMN`, etc.) needed to move the database schema from one version to the next, paired with a "down" method to reverse it. Migrations exist because a database schema is *stateful* — unlike application code, which you can simply redeploy, a database already contains real data that must be transformed in place, not replaced. The workflow is: after changing a model class or `OnModelCreating`, you run `dotnet ef migrations add SomeDescriptiveName`, which *diffs* your current model against the last known migration snapshot (`AppDbContextModelSnapshot.cs` in the same folder) and generates the new migration file automatically — you review it like any other code change, then apply it with `dotnet ef database update`, which runs any migrations not yet recorded in the database's own `__EFMigrationsHistory` table.

The reason you never hand-edit a production schema directly (via SSMS, say) is that doing so silently breaks this tracking: EF Core has no record of the change, so the next migration generated from your models will either try to redundantly recreate what you already added by hand, or worse, produce a migration that doesn't match what the database actually looks like, causing `database update` to fail or corrupt data on a future deploy. `Program.cs` actually documents this exact discipline inline:

```csharp
if (app.Environment.IsDevelopment())
{
    // Auto-migrate only in Development for a fast local inner loop. In real
    // production environments, migrations should be run as a controlled,
    // auditable pipeline step (e.g. an Azure DevOps release step or K8s Job)
    // BEFORE the new app version starts serving traffic - not on every pod
    // startup, which could race across multiple replicas.
    using var scope = app.Services.CreateScope();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    db.Database.Migrate();
}
```

`db.Database.Migrate()` applies any pending migrations automatically — extremely convenient locally, and deliberately restricted to `Development` here. In production, calling this from every pod's startup would be dangerous: if you run 3 replicas of the API and all 3 start at once, all 3 could try to run the same schema migration against the database simultaneously, racing each other and potentially corrupting the migration history table. The comment's guidance — run migrations as one controlled, auditable step before the new version starts serving traffic (a dedicated pipeline stage or Kubernetes Job that runs once) — is the standard production pattern.

## JWT authentication, from first principles

**JWT** stands for JSON Web Token. It's a compact, URL-safe string, structured as three base64url-encoded segments separated by dots: `header.payload.signature`. The header identifies the signing algorithm; the payload (called "claims") is a JSON object holding facts about the authenticated user — in this project's `JwtTokenService.GenerateToken`, that's the user's ID, email, a unique token ID (`jti`), and their roles:

```csharp
var claims = new List<Claim>
{
    new(ClaimTypes.NameIdentifier, user.Id),
    new(JwtRegisteredClaimNames.Sub, user.Id),
    new(ClaimTypes.Email, user.Email ?? string.Empty),
    new(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString())
};
claims.AddRange(roles.Select(role => new Claim(ClaimTypes.Role, role)));
```

The critical thing to understand is that the payload is only **encoded**, not encrypted — anyone holding a JWT can trivially base64-decode the middle segment and read every claim in plain text (paste any JWT into jwt.io and see for yourself). What makes a JWT trustworthy isn't secrecy of its contents; it's the **signature**, the third segment. `JwtTokenService` signs the token with `SigningCredentials(signingKey, SecurityAlgorithms.HmacSha256)`, where `signingKey` is derived from a secret (`Jwt:Key`) known only to the server. HMAC-SHA256 is a symmetric algorithm: the same key used to sign the token is used to verify it, which is exactly what `Program.cs` configures on the receiving side:

```csharp
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = jwtIssuer,
            ValidateAudience = true,
            ValidAudience = jwtAudience,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtKey)),
            ClockSkew = TimeSpan.FromMinutes(1)
        };
    });
```

When a request arrives with an `Authorization: Bearer <token>` header, the JWT bearer middleware recomputes the signature over the token's header+payload using its own copy of `jwtKey` and compares it to the signature segment in the token. If anyone tampered with even one character of the payload (say, changing their own role claim from `Customer` to `Admin`), the recomputed signature would no longer match, and the middleware rejects the token outright — this is the entire security guarantee of a JWT: it isn't *secret*, it's *tamper-evident*, and only as strong as the secrecy of the signing key. This is precisely why `Jwt__Key` must be supplied as an environment variable (or, in Kubernetes, a Secret) rather than committed into `appsettings.json`: anyone who obtains that key can mint arbitrary, validly-signed tokens claiming to be any user with any role, completely bypassing authentication. Note both `appsettings.json` and `appsettings.Production.json` in this project deliberately leave `Jwt:Key` as an empty string, with a comment explaining real values come only from `Jwt__Key`-style environment variables or Kubernetes Secrets — never from a committed file.

This project issues only an **access token** — the JWT itself, valid for 60 minutes (`DateTime.UtcNow.AddMinutes(60)` in `JwtTokenService`), sent with every subsequent authenticated request. It does not implement a **refresh token** (a separate, longer-lived, single-use credential that lets a client obtain a new access token without asking the user to log in again once the short-lived one expires). The code comment is explicit about this being a simplification for a teaching sample: "60 minute lifetime is a reasonable default for a teaching sample. In a real system this would likely be shorter, paired with refresh tokens." Shorter access token lifetimes limit the damage window if a token is stolen; refresh tokens let you keep that window short without forcing users to re-authenticate constantly.

## DTOs: why controllers never return EF entities directly

Every controller action in this project returns a **DTO** (Data Transfer Object) — a plain record type defined purely to shape an HTTP response or request body — instead of returning the EF Core entity class directly. Compare `Product` (the EF entity, in `Models/Product.cs`) to `ProductDto` (in `DTOs/ProductDto.cs`):

```csharp
// Models/Product.cs — the EF Core entity, mapped 1:1 to the database table
public class Product
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public decimal Price { get; set; }
    public int Stock { get; set; }
    public int CategoryId { get; set; }
    public Category Category { get; set; } = null!;   // navigation property
}

// DTOs/ProductDto.cs — the shape actually sent over HTTP
public record ProductDto(
    int Id, string Name, string Description, decimal Price,
    int Stock, int CategoryId, string CategoryName);
```

`ProductsController.GetAll` explicitly maps one to the other: `.Select(p => new ProductDto(p.Id, p.Name, p.Description, p.Price, p.Stock, p.CategoryId, p.Category.Name))`. There are several concrete reasons for this extra step rather than just serializing `Product` as JSON directly. First, decoupling: the database schema and the public API contract are allowed to evolve independently — you can rename an internal column or restructure a navigation property without silently breaking every client that deserializes the JSON response. Second, avoiding accidental data exposure: an EF entity often carries navigation properties or internal fields you never intend to expose (imagine a `PasswordHash` field on `ApplicationUser` — serializing the entity directly risks leaking it the moment someone adds a field to the model and forgets it's now in every API response). Third, avoiding circular reference and over-fetching problems: `Product.Category` links back to `Category.Products`, which links back to each product's `Category` again — serializing that graph directly can blow up or produce absurdly large, repetitive JSON; a DTO flattens exactly the fields a client needs (here, just `CategoryName` as a string, not the whole nested object).

## CORS: what it is and why the origin must match exactly

**CORS** (Cross-Origin Resource Sharing) is a browser-enforced security mechanism, not a server-side one. By default, a web page's JavaScript is only allowed (by the browser itself, via the "same-origin policy") to make `fetch`/XHR requests back to the exact origin (scheme + host + port) it was served from. When the Angular app running at `http://localhost:4200` tries to call an API at a different origin, the browser first sends a preflight `OPTIONS` request asking, in effect, "will you accept a request from `http://localhost:4200`?" — and the API's response headers must explicitly say yes, or the browser blocks the actual request from ever completing, silently, in JavaScript, before it reaches the server logic at all. This project's CORS setup:

```csharp
var allowedOrigins = (builder.Configuration["Cors:AllowedOrigin"] ?? "http://localhost:4200")
    .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

builder.Services.AddCors(options =>
{
    options.AddPolicy(CorsPolicyName, policy =>
    {
        policy.WithOrigins(allowedOrigins).AllowAnyHeader().AllowAnyMethod();
    });
});
```

`Cors:AllowedOrigin` (settable via the `Cors__AllowedOrigin` environment variable) must match the *exact* origin the browser sends in its `Origin` header — scheme, host, and port all have to line up character-for-character; `http://localhost:4200` and `http://ecommerce.local` are different origins even if they eventually resolve to the same server, and a trailing slash or wrong port causes a silent CORS rejection that's easy to misdiagnose as a backend bug when it's actually a browser-side block. In this project's Kubernetes/production topology, CORS ends up mattering less in practice than you'd expect, because the nginx frontend proxies `/api/*` requests same-origin (see doc 03) — but it still matters for local `ng serve` development, where Angular's dev server and the API run on genuinely different ports.

## `/health` vs `/health/live`: readiness vs liveness

`Program.cs` registers two distinct health check endpoints, and the distinction between them is foundational to how Kubernetes will manage this API later (docs 06 and 07):

```csharp
builder.Services.AddHealthChecks()
    .AddDbContextCheck<AppDbContext>(name: "database", tags: new[] { "ready" });

// /health — runs every registered check, including the DB check
app.MapHealthChecks("/health", new HealthCheckOptions { Predicate = _ => true });

// /health/live — runs NO checks, just confirms the process can respond
app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = _ => false });
```

`/health` is a **readiness** check: `Predicate = _ => true` means it runs every registered health check, including `AddDbContextCheck<AppDbContext>`, which actually attempts a lightweight database operation. If the database is unreachable, `/health` returns an unhealthy status. `/health/live` is a **liveness** check: `Predicate = _ => false` deliberately runs zero of the registered checks, meaning it only confirms the ASP.NET Core process itself is alive enough to accept an HTTP request and produce a response — it says nothing about the database. The reason this split exists, spelled out directly in the source comments, is that these two questions demand different *actions* from whatever is monitoring them: if the database goes down temporarily, you want the API pod pulled out of load-balancing rotation (because it genuinely can't serve real requests right now) without being killed and restarted, since restarting the process does nothing to fix a downed database and would just create a crash-loop storm the moment the database recovers, as every pod tries to reconnect simultaneously. A Kubernetes *readiness* probe should point at `/health` for exactly this reason (remove from rotation, don't restart); a Kubernetes *liveness* probe should point at `/health/live` (restart only if the process itself is truly wedged). Getting this backwards — pointing liveness at a DB-dependent check — is one of the most common real-world Kubernetes misconfigurations, and this project's inline comments call that out explicitly as the reason for the split.

## Key terms

- **Minimal hosting model**: the single-file `Program.cs` style (replacing the old `Startup.cs` split) where service registration and middleware configuration both happen top-to-bottom in one file, split by the `builder.Build()` call.
- **Dependency Injection (DI) container**: a framework-managed registry that constructs and supplies objects to classes that declare them as constructor parameters, instead of classes constructing their own dependencies.
- **DbContext**: EF Core's representation of a database session — tracks loaded entities, translates LINQ to SQL, and batches changes until `SaveChangesAsync()` is called.
- **Migration**: a generated, reviewable code file describing exactly how to evolve a database schema from one version to the next, applied via `dotnet ef database update`.
- **JWT (JSON Web Token)**: a signed (not encrypted) token format used to assert claims about an authenticated user; trustworthy because tampering invalidates its signature, not because its contents are hidden.
- **DTO (Data Transfer Object)**: a plain object shaped specifically for an API request/response, decoupled from the internal EF Core entity/database schema.
- **CORS (Cross-Origin Resource Sharing)**: a browser-enforced policy that blocks JavaScript from calling a different origin than the one that served the page, unless the server's response headers explicitly allow it.
- **Readiness vs. liveness probe**: readiness asks "should traffic be routed to this instance right now?"; liveness asks "should this process be killed and restarted?" — conflating the two causes unnecessary restarts during transient dependency outages.
