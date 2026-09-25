import Foundation

/// Resource bundle accessor for the AetherOracle shared assets.
///
/// The oracle's visual grammar — Themes (YAML), Syntax (tmLanguage + tree-sitter
/// queries), and Fonts — is a single portable bundle, decoupled from any shell.
/// Every platform window loads the *same* assets, so the æther looks identical
/// whether it is the macOS editor, the iOS companion, or a future WinUI3/GTK shell.
public enum AetherOracleResources {
    /// The `Bundle.module` for this resource-only target.
    public static var bundle: Bundle { .module }
}
