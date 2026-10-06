import Foundation

/// Errors from rendering a naming template.
public enum NamingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A `{token}` the template language does not define.
    case unknownToken(String)
    /// A `{` without a matching `}`.
    case unclosedToken
    /// The rendered name is empty.
    case emptyName
    /// The rendered name is longer than 200 bytes.
    case nameTooLong(Int)

    public var description: String {
        switch self {
        case let .unknownToken(token): return "unknown token {\(token)}"
        case .unclosedToken: return "a { has no matching }"
        case .emptyName: return "the template renders an empty name"
        case let .nameTooLong(bytes): return "the name is \(bytes) bytes, the limit is 200"
        }
    }
}

/// A file naming template such as `{project}_{index}_{description}`.
///
/// Tokens: `{project}`, `{index}` (1-based, zero padded to the width of the batch size, at
/// least two digits), `{description}` and `{originator}` (from `bext`), and `{name}` (the
/// current name without extension). Token values are sanitised: whitespace runs become `_`;
/// `/ : \ , ; * ? " < > |`, control characters and leading dots are removed. The extension of the
/// original file is kept.
public struct NamingTemplate: Sendable, Equatable {
    /// The template text.
    public var pattern: String

    /// The tokens the template understands.
    public static let tokens = ["project", "index", "description", "originator", "name"]

    /// Creates a template.
    public init(_ pattern: String) {
        self.pattern = pattern
    }

    /// Values for one file.
    public struct Context: Sendable, Equatable {
        /// Value of `{project}`.
        public var project: String
        /// 1-based position of the file in the batch, for `{index}`.
        public var index: Int
        /// Files in the batch; sets the zero padding of `{index}`.
        public var total: Int
        /// Value of `{description}`.
        public var description: String
        /// Value of `{originator}`.
        public var originator: String
        /// Current file name with extension; `{name}` uses it without the extension.
        public var originalName: String

        /// Creates a context.
        public init(project: String, index: Int, total: Int, description: String, originator: String, originalName: String) {
            self.project = project
            self.index = index
            self.total = total
            self.description = description
            self.originator = originator
            self.originalName = originalName
        }
    }

    /// The new file name, extension included.
    public func render(_ context: Context) throws -> String {
        var out = ""
        var token: String?
        for character in pattern {
            if var current = token {
                if character == "}" {
                    out += try value(for: current, context)
                    token = nil
                } else {
                    current.append(character)
                    token = current
                }
            } else if character == "{" {
                token = ""
            } else {
                out.append(character)
            }
        }
        guard token == nil else { throw NamingError.unclosedToken }
        let base = NamingTemplate.sanitise(out)
        guard !base.isEmpty else { throw NamingError.emptyName }
        let ext = (context.originalName as NSString).pathExtension
        let name = ext.isEmpty ? base : "\(base).\(ext)"
        guard name.utf8.count <= 200 else { throw NamingError.nameTooLong(name.utf8.count) }
        return name
    }

    private func value(for token: String, _ context: Context) throws -> String {
        switch token {
        case "project": return context.project
        case "index":
            let width = max(2, String(max(context.total, 1)).count)
            let digits = String(context.index)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        case "description": return context.description
        case "originator": return context.originator
        case "name": return (context.originalName as NSString).deletingPathExtension
        default: throw NamingError.unknownToken(token)
        }
    }

    /// Characters dropped from token values: path separators, and characters other file
    /// systems or delivery specs commonly reject.
    static let removed: Set<Unicode.Scalar> = ["/", ":", "\\", ",", ";", "*", "?", "\"", "<", ">", "|"]

    /// Makes text safe as a file name component.
    public static func sanitise(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            if NamingTemplate.removed.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                continue
            }
            if pendingSpace {
                out.append("_")
                pendingSpace = false
            }
            out.unicodeScalars.append(scalar)
        }
        while out.hasPrefix(".") {
            out.removeFirst()
        }
        return out
    }
}

/// One line of the rename preview.
public struct NamingPreviewItem: Sendable, Equatable, Identifiable {
    /// The row id.
    public var id: UUID
    /// The current file name.
    public var oldName: String
    /// The new name, or nil when the template failed for this file.
    public var newName: String?
    /// Why the rename cannot happen (template error, duplicate name), if it cannot.
    public var problem: String?
}
