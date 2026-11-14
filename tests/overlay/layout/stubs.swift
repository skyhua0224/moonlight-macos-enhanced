// Stand-ins for the app's string lookup and harness switch, so the overlay views compile on their own.
import Foundation

func DL(_ key: String) -> String { key.split(separator: ".").last.map(String.init) ?? key }
func DLf(_ key: String, _ args: CVarArg...) -> String { String(format: key, arguments: args) }
func conceptEnv(_ key: String) -> String? { nil }
