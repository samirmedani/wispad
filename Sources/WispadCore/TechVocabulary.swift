import Foundation

/// Vocabulaire technique anglais courant dans une dictée française (franglais de développeur).
/// Envoyé à la reconnaissance comme mots-clés (`keyterm` chez xAI) et à la correction comme référence
/// d'orthographe, pour que « OAuth », « Vercel » ou « throughput » ne soient ni écorchés ni francisés.
/// Les verbes anglais courts (push, fix, tools…) y sont aussi : mesuré sur de vraies dictées, ils aident la
/// reconnaissance sans angliciser le français (« un prix fixe », « les outils » restent intacts dans le banc).
public enum TechVocabulary {
    /// Plateformes, protocoles, outils.
    public static let products = [
        "OAuth", "OAuth 2.0", "MCP", "REST", "WebSocket", "gRPC", "GraphQL", "GitHub", "GitLab", "Vercel",
        "Cloudflare Workers", "TypeScript", "JavaScript", "PostgreSQL", "OpenTelemetry", "Redis", "S3", "JSON",
        "CI/CD", "Next.js", "React", "Docker", "Kubernetes", "Node.js", "npm", "pnpm", "SDK", "API", "LLM",
    ]

    /// Expressions techniques anglaises de plusieurs mots ou peu ambiguës.
    public static let phrases = [
        "serverless", "serverless functions", "tool call", "pull request", "environment variable",
        "previous deployment", "deployment", "rollback", "health check", "fallback", "rate limit",
        "exponential backoff", "latency", "throughput", "observability", "token usage", "AI inference",
        "AI agents", "speech-to-text", "text-to-speech", "time-to-first-token", "workload", "benchmark",
        "monitoring", "frontend", "backend", "startup",
    ]

    /// Familles de matériel : les noms de gamme aident à reconnaître les références qui suivent.
    public static let hardware = [
        "Ryzen", "Ryzen 7", "Ryzen 9", "X3D", "Threadripper", "Intel Core", "i9", "i7", "RTX", "GeForce",
        "Radeon", "NVIDIA", "VRAM",
        "DDR3", "DDR4", "DDR5", "RAM", "Go", "To", "MHz", "GHz", "SSD", "NVMe", "CPU", "GPU",
    ]

    /// Verbes et noms anglais courts du quotidien d'un développeur.
    public static let shortWords = [
        "push", "fix", "pull", "merge", "fetch", "commit", "deploy", "build", "tools", "tool", "settings",
        "errors", "missing", "fail",
    ]

    /// Assemblé une fois : la liste sert à chaque dictée (mots-clés, consigne, garde-fou).
    public static let all: [String] = products + phrases + hardware + shortWords

    /// Jargon de l'IA, fréquent dans une dictée technique et souvent entendu comme des mots français : le
    /// 28 octobre 2026, abliterated est devenu « habilitée RAID ». Donné à la correction et au garde-fou seulement :
    /// les mots-clés de la reconnaissance (100 au plus chez xAI) restent ceux mesurés sur les bancs. Pas de mot dont
    /// l'équivalent français est le plus courant à l'oral (« raisonnement », « quantifié ») : il ne doit pas être traduit.
    public static let ai = [
        "abliterated", "uncensored", "fine-tuning", "LoRA", "dataset", "embeddings", "RAG", "prompt", "system prompt",
        "Ollama", "Hugging Face", "GGUF", "open weights", "jailbreak",
    ]

    /// Vocabulaire de la correction et du garde-fou : celui de la reconnaissance, puis le jargon de l'IA.
    public static let correction: [String] = all + ai
}

/// Mots-clés envoyés à la reconnaissance : d'abord le dictionnaire de l'utilisateur, puis les termes du
/// texte voisin, puis ceux des dictées précédentes, puis le vocabulaire technique, dans la limite d'xAI
/// (100 termes de 50 caractères).
public enum RecognitionHints {
    public static func keyterms(dictionary: [String], context: [String], prior: [String] = []) -> [String] {
        KeytermList.sanitize(dictionary + context + prior + TechVocabulary.all)
    }
}
