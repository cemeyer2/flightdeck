import Foundation

// Recognises developer tools from a process's executable and command line: which listening process is a Vite dev
// server, a Rails app, Postgres or Ollama (`DevClassifier.server`), and which running process is part of a build
// (`DevClassifier.build`). Pure string matching, so it is unit-tested with synthetic command lines.
//
// Interpreted tools need the command line: Vite, Next.js and webpack all run as `node`, uvicorn and Django as
// `python3.12`, Rails and Puma as `ruby`. The interpreter is identified from the executable's file name, then the
// arguments are searched for a known script or module.

/// What a dev process is, for display: "Vite" in the "JavaScript" family.
public struct DevToolKind: Hashable, Sendable, Codable {
    public enum Family: String, Sendable, Codable, CaseIterable {
        case javascript = "JavaScript", python = "Python", ruby = "Ruby", jvm = "JVM", go = "Go", rust = "Rust",
             php = "PHP", elixir = "Elixir", dotnet = ".NET", database = "Database", ai = "AI model server", container = "Containers"
    }
    public var name: String
    public var family: Family
    public init(_ name: String, _ family: Family) { self.name = name; self.family = family }
}

public enum DevClassifier {
    /// Lower-cased file name of an executable path, with version suffixes removed so "python3.12", "ruby3.3" and
    /// "node22" match their tool ("python", "ruby", "node").
    static func baseName(_ path: String) -> String {
        var b = (path as NSString).lastPathComponent.lowercased()
        while let last = b.last, last.isNumber || last == "." { b.removeLast() }
        return b
    }

    /// Classifies a listening process. `executable` is the full path (proc_pidpath) or, failing that, the process
    /// name; `args` is argv including argv[0]. Returns nil for anything that isn't a recognised developer tool, so
    /// ordinary apps that happen to listen (Spotify, AirPlay, Raycast) stay out of the list.
    public static func server(executable: String, args: [String]) -> DevToolKind? {
        let exe = baseName(executable)
        // argv[0] can be rewritten as a process title (Puma, Postgres backends, gunicorn workers), so it is searched too.
        let words = args.flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "=" || $0 == ":" }) }.map { $0.lowercased() }
        let joined = args.joined(separator: " ").lowercased()
        func has(_ w: String) -> Bool { words.contains(w) }

        // Whole-path matches first: app bundles and container engines.
        if executable.contains("/LM Studio.app/") || exe == "lms" || exe == "llmster" { return .init("LM Studio", .ai) }
        if executable.contains("/OrbStack.app/") { return .init("OrbStack port forward", .container) }
        if executable.contains("/Docker.app/") || exe.hasPrefix("com.docker.") || exe == "docker-proxy" || exe == "vpnkit-bridge" {
            return .init("Docker port forward", .container)
        }
        if exe == "limactl" || exe == "colima" { return .init("Lima/Colima port forward", .container) }
        if executable.contains("/Rancher Desktop.app/") { return .init("Rancher Desktop port forward", .container) }

        switch exe {
        case "node", "nodejs", "bun", "deno":
            let runtime = exe == "bun" ? "Bun" : exe == "deno" ? "Deno" : "Node.js"
            let known: [(String, String)] = [
                ("vite", "Vite"), ("next", "Next.js"), ("next-server", "Next.js"), ("webpack-dev-server", "webpack dev server"),
                ("nuxt", "Nuxt"), ("nuxi", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"), ("react-scripts", "Create React App"),
                ("parcel", "Parcel"), ("storybook", "Storybook"), ("expo", "Expo"), ("react-native", "Metro (React Native)"),
                ("ng", "Angular CLI"), ("svelte-kit", "SvelteKit"), ("gatsby", "Gatsby"), ("nodemon", "nodemon"),
                ("ts-node", "ts-node"), ("tsx", "tsx"), ("http-server", "http-server"), ("serve", "serve"), ("json-server", "json-server"),
            ]
            // `webpack serve` before the table, whose generic "serve" entry would otherwise claim it.
            if has("webpack") && has("serve") { return .init("webpack dev server", .javascript) }
            for (w, name) in known where has(w) || has(w + ".js") || has(w + ".mjs") { return .init(name, .javascript) }
            return .init(runtime, .javascript)
        case "python", "pythonw":
            if has("manage.py") && has("runserver") { return .init("Django runserver", .python) }
            let known: [(String, String)] = [
                ("uvicorn", "uvicorn"), ("gunicorn", "gunicorn"), ("hypercorn", "Hypercorn"), ("daphne", "Daphne"),
                ("flask", "Flask"), ("jupyter-lab", "JupyterLab"), ("jupyterlab", "JupyterLab"), ("jupyter-notebook", "Jupyter Notebook"),
                ("notebook", "Jupyter Notebook"), ("jupyter", "Jupyter"), ("streamlit", "Streamlit"), ("mkdocs", "MkDocs"),
                ("fastapi", "FastAPI"), ("http.server", "Python http.server"), ("celery", "Celery"),
            ]
            for (w, name) in known where has(w) { return .init(name, .python) }
            if joined.contains("ipykernel") { return .init("Jupyter kernel", .python) }
            return .init("Python", .python)
        case "uvicorn", "gunicorn", "hypercorn", "flask", "jupyter-lab", "jupyter-notebook", "streamlit":
            return .init(exe == "jupyter-lab" ? "JupyterLab" : exe == "jupyter-notebook" ? "Jupyter Notebook" : exe, .python)
        case "ruby":
            if has("rails") || joined.contains("bin/rails") { return .init("Rails", .ruby) }
            if joined.hasPrefix("puma") || has("puma") { return .init("Puma", .ruby) }
            if has("unicorn") { return .init("Unicorn", .ruby) }
            if has("jekyll") { return .init("Jekyll", .ruby) }
            if has("rackup") { return .init("Rack", .ruby) }
            return .init("Ruby", .ruby)
        case "puma", "rails", "jekyll":
            return .init(exe == "rails" ? "Rails" : exe.capitalized, .ruby)
        case "java":
            if joined.contains("gradledaemon") || joined.contains("gradle-launcher") || joined.contains("org.gradle") { return .init("Gradle daemon", .jvm) }
            if joined.contains("org.springframework") || joined.contains("spring-boot") { return .init("Spring Boot", .jvm) }
            if joined.contains("org.elasticsearch") { return .init("Elasticsearch", .database) }
            if joined.contains("kafka.kafka") || joined.contains("kafka-server") { return .init("Kafka", .database) }
            if joined.contains("org.apache.catalina") { return .init("Tomcat", .jvm) }
            if joined.contains("quarkus") { return .init("Quarkus", .jvm) }
            if let i = args.firstIndex(of: "-jar"), i + 1 < args.count { return .init("Java (\((args[i + 1] as NSString).lastPathComponent))", .jvm) }
            return .init("Java", .jvm)
        case "gradle": return .init("Gradle", .jvm)
        case "go": return .init("go run", .go)
        case "air": return .init("air (Go live reload)", .go)
        case "dlv": return .init("Delve debugger", .go)
        case "cargo": return .init(has("watch") ? "cargo watch" : "cargo run", .rust)
        case "trunk": return .init("Trunk", .rust)
        case "php", "php-fpm":
            if has("artisan") && has("serve") { return .init("Laravel (artisan serve)", .php) }
            if exe == "php-fpm" { return .init("PHP-FPM", .php) }
            if has("-s") { return .init("PHP built-in server", .php) }
            return .init("PHP", .php)
        case "beam.smp", "beam": return .init(joined.contains("phx") || joined.contains("phoenix") ? "Phoenix" : "Erlang/Elixir", .elixir)
        case "dotnet": return .init(".NET", .dotnet)
        case "postgres", "postmaster": return .init("PostgreSQL", .database)
        case "mysqld", "mariadbd": return .init(exe == "mysqld" ? "MySQL" : "MariaDB", .database)
        case "redis-server": return .init("Redis", .database)
        case "valkey-server": return .init("Valkey", .database)
        case "mongod", "mongos": return .init("MongoDB", .database)
        case "memcached": return .init("Memcached", .database)
        case "clickhouse", "clickhouse-server": return .init("ClickHouse", .database)
        case "influxd": return .init("InfluxDB", .database)
        case "minio": return .init("MinIO", .database)
        case "ollama": return .init("Ollama", .ai)
        case "llama-server": return .init("llama.cpp server", .ai)
        default: break
        }
        // Compiled Go and Rust programs have arbitrary names, but `go run` builds into a go-build temp directory and
        // Cargo into the project's target/ directory, so the path gives them away.
        if executable.contains("/go-build") { return .init("Go program (go run)", .go) }
        if executable.contains("/target/debug/") || executable.contains("/target/release/") { return .init("Rust program (cargo target)", .rust) }
        return nil
    }

    /// Classifies a running process as part of a build, or nil. `name` is the process name; `args` is only needed
    /// for interpreted tools (tsc runs as node, Gradle as java), so callers may pass nil for everything else and
    /// `needsArguments` says when to fetch them.
    public static func build(name: String, args: [String]?) -> String? {
        let n = baseName(name)
        switch n {
        case "xcodebuild", "xcbbuildservice", "swift-build": return n == "xcbbuildservice" ? "Xcode build service" : n
        case "swift-frontend", "swiftc", "swift-driver": return "Swift compiler"
        case "clang", "clang++", "cc", "c++", "cc1", "cc1plus": return "clang"
        case "ld", "ld64", "ld-prime", "lld", "ld64.lld": return "linker"
        case "ibtool", "actool", "ibtoold", "assetutil": return "Xcode resource compiler"
        case "cargo": return "cargo"
        case "rustc": return "rustc"
        case "esbuild": return "esbuild"
        case "swc": return "swc"
        case "make", "gmake", "ninja", "cmake": return n
        case "gradle": return "Gradle"
        case "go": return args.map { $0.contains("build") || $0.contains("test") } == true ? "go build" : nil
        case "compile", "link": return nil   // Go's own compiler steps are too generically named to claim
        case "node", "bun", "deno":
            guard let a = args?.joined(separator: " ").lowercased() else { return nil }
            if a.contains("/tsc") || a.hasSuffix(" tsc") || a.contains("typescript/bin") { return "tsc" }
            if a.contains("webpack") && !a.contains("serve") && !a.contains("dev-server") { return "webpack" }
            if a.contains("vite") && a.contains(" build") { return "vite build" }
            if a.contains("next") && a.contains(" build") { return "next build" }
            return nil
        case "java":
            guard let a = args?.joined(separator: " ").lowercased() else { return nil }
            return a.contains("gradledaemon") || a.contains("org.gradle") ? "Gradle" : (a.contains("org.codehaus.plexus") || a.contains("maven") ? "Maven" : nil)
        default: return nil
        }
    }

    /// True when `build(name:args:)` can only decide with the command line.
    public static func needsArguments(_ name: String) -> Bool { ["node", "bun", "deno", "java", "go"].contains(baseName(name)) }
}
