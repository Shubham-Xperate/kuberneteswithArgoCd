# 03 — The Angular 17 Frontend

## Standalone components: no `NgModule` in sight

If you've seen older Angular code, you probably remember every component being declared inside an `NgModule` — a class decorated with `@NgModule({ declarations: [...], imports: [...] })` that bundled a group of components, directives, and pipes together and exported them for use elsewhere. Angular 14+ introduced **standalone components**, and this project (Angular 17) uses them exclusively — there is no `AppModule` anywhere. Look at `frontend/src/app/app.component.ts`:

```typescript
@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, RouterLink, RouterOutlet],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css'
})
export class AppComponent {
  constructor(
    public auth: AuthService,
    public cart: CartService,
    private router: Router
  ) {}
  ...
}
```

`standalone: true` means this component declares its own dependencies directly in its own `imports` array — here, `CommonModule` (for structural directives like `*ngIf`/`*ngFor` used in the template), `RouterLink`, and `RouterOutlet` — rather than relying on some enclosing `NgModule` to have already imported them. The practical benefit is locality: to understand what a component needs, you read that one component's decorator, not trace through a separate module file that might declare a dozen unrelated components together. It also means the Angular compiler can tree-shake more aggressively, since dependencies are declared per-component instead of pulled in wholesale via a module that might import far more than any single component actually uses.

## Bootstrapping without a module: `app.config.ts`

Without an `NgModule`, application-wide providers (things every part of the app needs access to, like the router or the HTTP client) have to be registered somewhere else. That's `frontend/src/app/app.config.ts`:

```typescript
export const appConfig: ApplicationConfig = {
  providers: [
    provideRouter(routes),
    provideHttpClient(withInterceptors([authInterceptor]))
  ]
};
```

`provideRouter(routes)` wires up Angular's router using the route table defined in `app.routes.ts`. `provideHttpClient(withInterceptors([authInterceptor]))` sets up Angular's `HttpClient` — the service used throughout this app to call the backend API — and registers `authInterceptor` (covered below) as a **functional interceptor** that runs on every outgoing HTTP request. This `ApplicationConfig` object is handed to Angular's bootstrap call in `main.ts`, replacing what used to be an `NgModule`'s job of assembling the root injector.

## The Router and the auth guard

`frontend/src/app/app.routes.ts` defines the app's route table as a plain array, no module wrapping required:

```typescript
export const routes: Routes = [
  { path: '', component: CatalogComponent },
  { path: 'products/:id', component: ProductDetailComponent },
  { path: 'cart', component: CartComponent },
  { path: 'login', component: LoginComponent },
  { path: 'register', component: RegisterComponent },
  { path: 'orders', component: OrdersComponent, canActivate: [authGuard] },
  { path: '**', redirectTo: '' }
];
```

Every entry maps a URL path to the component that should render there; `:id` in `products/:id` is a route parameter, later read inside `ProductDetailComponent` to know which product to fetch. The `**` wildcard at the end catches any URL that matched nothing above and redirects to the catalog — a fallback for typos or stale links. The `orders` route carries `canActivate: [authGuard]`, which is Angular's **route guard** mechanism: before the router actually activates (renders) a route, it runs every function listed in `canActivate` and only proceeds if all of them return `true` (or a value the router accepts as permission). This project's guard, in `frontend/src/app/core/auth.guard.ts`, is written as a `CanActivateFn` — the modern, standalone-friendly functional style, replacing the older class-based `CanActivate` interface:

```typescript
export const authGuard: CanActivateFn = () => {
  const auth = inject(AuthService);
  const router = inject(Router);

  if (auth.isLoggedIn()) {
    return true;
  }
  return router.createUrlTree(['/login']);
};
```

`inject()` is how a functional guard (which isn't a class, so it has no constructor to declare dependencies in) still gets access to Angular's DI container — it pulls `AuthService` and `Router` out of the current injector context at call time. If the user isn't logged in, instead of just returning `false` (which would silently block navigation with no explanation), the guard returns `router.createUrlTree(['/login'])` — the router treats a returned `UrlTree` as "redirect here instead," so an unauthenticated user hitting `/orders` is transparently sent to the login page rather than seeing a blank or broken screen.

## Services and state: signals in `CartService`

Angular's convention for anything that isn't presentation logic — shared state, business logic, API calls — is a `@Injectable` **service**, injected wherever it's needed via the same DI mechanism the backend uses. `frontend/src/app/core/cart.service.ts` is a clean example, and it uses Angular's newer **signals** API for reactive state rather than RxJS `BehaviorSubject`s (which is how this same pattern would have been written a few years ago):

```typescript
@Injectable({ providedIn: 'root' })
export class CartService {
  private items = signal<CartItem[]>([]);

  readonly total = computed(() =>
    this.items().reduce((sum, item) => sum + item.product.price * item.quantity, 0)
  );

  getItems() {
    return this.items;
  }

  addToCart(product: Product, quantity: number): void {
    if (quantity <= 0) return;
    const current = this.items();
    const existing = current.find((i) => i.product.id === product.id);
    if (existing) {
      this.items.set(current.map((i) =>
        i.product.id === product.id ? { ...i, quantity: i.quantity + quantity } : i
      ));
    } else {
      this.items.set([...current, { product, quantity }]);
    }
  }
  ...
}
```

`providedIn: 'root'` registers this service as a singleton for the whole application — every component that injects `CartService` gets the exact same instance, which is exactly what you want for a shared cart: adding an item on the product detail page must be visible on the cart page without any extra plumbing. `signal<CartItem[]>([])` creates a reactive container holding the cart's current items; reading it (`this.items()`, note the function-call syntax) returns the current value, and Angular's change detection automatically knows to re-render any template that read that signal whenever `.set(...)` gives it a new value. `computed(() => ...)` derives `total` automatically from `items` — it recalculates only when `items` actually changes, and consumers just read `cart.total()` without manually recomputing sums themselves. Note the cart is deliberately **not** persisted to the backend or `localStorage` — the code comment states it lives only for the current page session and is sent to the API as a single `POST /api/orders` payload at checkout, which is a reasonable simplification for a teaching project (a production e-commerce cart would likely persist across sessions).

## HttpClient and the functional `authInterceptor`

Every API call in this app goes through Angular's `HttpClient`, and every one of those calls passes through `frontend/src/app/core/auth.interceptor.ts` first, because it was registered in `app.config.ts` via `withInterceptors([authInterceptor])`. An **interceptor** sits in the middle of every outgoing request (and incoming response) and can inspect or rewrite it — this is the modern **functional interceptor** style (an `HttpInterceptorFn`), replacing the older class-based `HttpInterceptor` interface:

```typescript
const PUBLIC_PATHS = ['/auth/login', '/auth/register'];

export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(AuthService);
  const token = auth.getToken();

  const isPublicEndpoint = PUBLIC_PATHS.some((path) => req.url.includes(path));

  if (token && !isPublicEndpoint) {
    const cloned = req.clone({
      setHeaders: { Authorization: `Bearer ${token}` }
    });
    return next(cloned);
  }
  return next(req);
};
```

This is *why* you never see application code manually attaching an `Authorization` header before calling the API — this interceptor does it centrally, once, for every request that needs it. `req.clone({ setHeaders: {...} })` is necessary because Angular's `HttpRequest` objects are immutable; you can't mutate the original request object, so the interceptor produces a modified copy and passes that copy along the chain via `next(cloned)`. The `PUBLIC_PATHS` exclusion list exists because attaching a stale or irrelevant bearer token to the login/register calls themselves would be pointless at best (those endpoints don't require authentication) and could theoretically confuse a backend that (incorrectly) tried to validate a token on a public endpoint — cheap defensive coding.

## The SPA build process: Angular has no server-side runtime in production

Running `ng build --configuration production` (as `frontend/Dockerfile` does) compiles every TypeScript file, template, and stylesheet in the Angular project down into a fixed set of static files: HTML, JavaScript bundles, and CSS, output under `dist/ecommerce-web/browser/` per this project's `angular.json` output path convention. This is the fundamental nature of a **Single Page Application (SPA)**: once built, there is no Node.js process, no Angular "server," nothing dynamic running to produce these files at request time. They're just files. This is precisely why the `frontend/Dockerfile`'s second stage is plain `nginx:1.27-alpine` serving `/usr/share/nginx/html` — nginx has no idea it's serving an "Angular app"; as far as it's concerned, it's serving static HTML/JS/CSS, identically to any other static website. All of the app's actual logic — routing, rendering, API calls — executes entirely in the user's browser after those files download.

## The runtime-config problem: why baking an API URL into the bundle is an anti-pattern

Here is the core problem this section exists to solve. A naive Angular setup keeps environment-specific values (like the backend's URL) in `environment.ts`/`environment.prod.ts` files, and the build process inlines whichever one matches the build configuration directly into the compiled JavaScript bundle. That means the API URL becomes a hardcoded string baked permanently into `main.js` at the moment `ng build` runs. Consider what that implies for a real deployment pipeline: if dev, staging, and production each need a different backend URL, you now need to run `ng build` three separate times, once per environment, producing three different JavaScript bundles — even though the application source code is byte-for-byte identical across all three. That directly violates one of the core "production-grade" properties from doc 01: the exact artifact that was tested is the one that ships. If staging's bundle and production's bundle are literally different files (different compiled JS, because a different string got inlined), then testing in staging never really validated the artifact that reaches production — it validated a look-alike sibling built from the same source. You also can't "promote" a build the way you promote a Docker image tag; you'd have to rebuild for every target, reintroducing exactly the "did the same code that passed tests actually reach prod" uncertainty that container images and immutable artifacts are supposed to eliminate.

This project solves it with a small, deliberate mechanism often called **runtime configuration injection**, and it's worth tracing end to end because every piece matters.

**Step 1 — a plain, unbundled JS file.** `frontend/src/assets/env.js`:

```javascript
window.__env = {
  apiUrl: '/api'
};
```

This file is deliberately *not* a TypeScript file and is never processed by Angular's build tooling — it's copied byte-for-byte into the output as a static asset. Because it's untouched by the bundler, it can be freely rewritten after the build completes, which is exactly the trick.

**Step 2 — loaded before the app bundle, via `index.html`:**

```html
<script src="assets/env.js"></script>
```
followed later by Angular's own compiled `main.js`. Script tags execute in document order, so `window.__env` is guaranteed to already exist by the time Angular's code starts running and tries to read it.

**Step 3 — a service reads it at runtime**, `frontend/src/app/core/config.service.ts`:

```typescript
@Injectable({ providedIn: 'root' })
export class ConfigService {
  get apiUrl(): string {
    return window.__env?.apiUrl ?? '/api';
  }
}
```

Nothing in the compiled Angular bundle contains a hardcoded backend URL. `ConfigService.apiUrl` is a getter that reads `window.__env.apiUrl` fresh, every single time it's accessed, straight off the global `window` object — a value that lives entirely outside the compiled JS.

**Step 4 — the container rewrites `env.js` at startup**, `frontend/docker-entrypoint.sh`:

```sh
set -e
: "${API_URL:=/api}"

cat <<EOF > /usr/share/nginx/html/assets/env.js
window.__env = {
  apiUrl: "${API_URL}"
};
EOF

exec "$@"
```

This script is set as the Docker image's `ENTRYPOINT` (see `frontend/Dockerfile`: `ENTRYPOINT ["/docker-entrypoint.sh"]`, `CMD ["nginx", "-g", "daemon off;"]`), meaning it runs every time a container starts, *before* nginx itself launches. `: "${API_URL:=/api}"` is a shell idiom that defaults `API_URL` to `/api` if the environment variable wasn't set. The `cat <<EOF > ...` block then literally overwrites `assets/env.js` on disk with a new value, baked from whatever `API_URL` environment variable was passed into the container. Finally `exec "$@"` replaces the shell process with nginx (the `CMD` array from the Dockerfile), so nginx starts serving the *just-rewritten* `env.js` file.

Put together: the exact same Docker image — the exact same compiled JavaScript — can run in dev, staging, and production, with each environment simply supplying a different `API_URL` environment variable to the container (or Kubernetes Pod spec) at deploy time. No rebuild, no recompilation, no risk of "the code we tested isn't quite the code we shipped." In this project's Kubernetes setup, this same effect can alternatively be achieved by mounting a ConfigMap directly over `/usr/share/nginx/html/assets/env.js`, bypassing the entrypoint script's rewrite entirely — either mechanism lands on the identical end state, `window.__env.apiUrl` pointing at whatever this specific environment's backend actually is.

## Nginx's role: proxying `/api/` and SPA fallback routing

`frontend/nginx.conf` does two jobs beyond simply serving static files:

```nginx
location / {
    try_files $uri $uri/ /index.html;
}

location /api/ {
    proxy_pass http://ecommerce-api:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

`try_files $uri $uri/ /index.html;` is the standard SPA fallback rule: nginx first tries to serve the requested path as a literal file, then as a directory, and if neither exists, falls back to serving `index.html` regardless of what the URL path actually was. This matters because Angular's router handles paths like `/products/3` entirely client-side — there is no real file at that path on disk. Without this fallback, a hard refresh (or a shared link) pointing at `/products/3` would hit nginx directly, find no matching file, and return a bare 404, even though the Angular app is perfectly capable of rendering that route once its JavaScript loads. `location /api/ { proxy_pass http://ecommerce-api:8080; ... }` reverse-proxies any request under `/api/` to the backend, at the hostname `ecommerce-api` port `8080` — this hostname is not a real public domain, it's a Kubernetes Service DNS name (or, in Compose, a container name on the same network) that only resolves inside the same cluster/network the API is also running in. Because the frontend proxies the API under its own origin, the browser sees only one origin for both the page and its API calls, which is also why CORS (doc 02) matters less here than it would if the frontend called the API's own separate origin directly.

## Key terms

- **Standalone component**: an Angular component that declares its own dependencies via an `imports` array, without needing an enclosing `NgModule`.
- **Functional interceptor / guard**: the newer, function-based (not class-based) style for Angular `HttpClient` interceptors and route guards, using `inject()` to access DI-provided services outside a constructor.
- **Signal**: Angular's reactive primitive for holding a value that automatically triggers UI updates wherever it's read, read via calling it as a function (e.g., `items()`).
- **SPA (Single Page Application)**: a web app compiled into static assets with no server-side rendering step; all routing and rendering happen in the browser after initial load.
- **Runtime configuration injection**: supplying environment-specific values (like an API URL) to an already-built static bundle at container startup, instead of baking them in at build time — enables one artifact to be promoted across environments unmodified.
- **Reverse proxy**: a server (here, nginx) that forwards incoming requests to another backend service on the caller's behalf, so the caller only ever sees one origin.
