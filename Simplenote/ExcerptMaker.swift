import Foundation

// MARK: - ExcerptMaker: Generate excerpt from a note with specified keywords
//
@objc
final class ExcerptMaker: NSObject {
    private var regexp: NSRegularExpression?
    private var keywords: [String]?

    /// Update with search keywords
    ///
    @objc
    func update(withKeywords keywords: [String]?) {
        guard keywords != self.keywords else {
            return
        }

        self.keywords = keywords

        guard let keywords = keywords, !keywords.isEmpty else {
            regexp = nil
            return
        }

        regexp = NSRegularExpression.regexForExcerpt(withKeywords: keywords)
    }

    /// Generate and return excerpt from the note. Excerpt is based on keywords
    ///
    func excerpt(from note: Note) -> String? {
        guard let regexp = regexp, let content = note.content else {
            return note.bodyPreview
        }

        let foldedContent = content.folding(options: [.diacriticInsensitive], locale: .current)

        let bodyRange = NoteContentHelper.structure(of: foldedContent).body
        guard bodyRange.location != NSNotFound else {
            return nil
        }

        let excerptRange = regexp.rangeOfFirstMatch(in: foldedContent,
                                                    options: [],
                                                    range: bodyRange)
        guard excerptRange.location != NSNotFound else {
            return note.bodyPreview
        }

        var excerpt: String = {
            if foldedContent.nsString.length == content.nsString.length {
                return content.nsString.substring(with: excerptRange)
            }
            return foldedContent.nsString.substring(with: excerptRange)
        }()
        excerpt = excerpt.nsString.replacingNewlinesWithSpaces()
        if excerptRange.location > bodyRange.location {
            excerpt = "…" + excerpt
        }
        return excerpt
    }
}