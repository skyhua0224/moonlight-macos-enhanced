import SwiftUI
import Foundation

struct ReleaseNotesDocument {
  struct Block: Identifiable {
    let id: Int
    var text: AttributedString
    let headingLevel: Int?
    let marker: String?
    let isCode: Bool
  }

  let blocks: [Block]

  init(markdown: String) {
    guard let parsed = try? AttributedString(markdown: markdown) else {
      blocks = [Block(id: 0, text: AttributedString(markdown), headingLevel: nil, marker: nil, isCode: false)]
      return
    }
    var result: [Block] = []
    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      // Foundation orders components from the innermost block outward.
      // The first identity preserves individual list-item paragraphs.
      let identity = components.first?.identity ?? 0
      var text = AttributedString(parsed[run.range])
      text.presentationIntent = nil
      if result.last?.id == identity {
        result[result.count - 1].text += text
        continue
      }
      var heading: Int?
      var ordinal: Int?
      var unordered = false
      var isCode = false
      for component in components {
        switch component.kind {
        case .header(let level): heading = level
        case .codeBlock: isCode = true
        default: break
        }
      }
      // Pair the nearest item with its enclosing list, so an unordered
      // ancestor cannot turn a nested ordered list into bullets.
      for component in components {
        if ordinal == nil, case .listItem(let number) = component.kind {
          ordinal = number
        } else if ordinal != nil {
          if case .unorderedList = component.kind {
            unordered = true
            break
          }
          if case .orderedList = component.kind { break }
        }
      }
      let marker = ordinal.map { unordered ? "•" : "\($0)." }
      result.append(Block(id: identity, text: text, headingLevel: heading, marker: marker, isCode: isCode))
    }
    blocks = result
  }
}

struct ReleaseNotesView: View {
  private let document: ReleaseNotesDocument

  init(markdown: String) {
    document = ReleaseNotesDocument(markdown: markdown)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(document.blocks) { block in
        ReleaseNotesBlockView(block: block)
      }
    }
    .textSelection(.enabled)
  }
}

private struct ReleaseNotesBlockView: View {
  let block: ReleaseNotesDocument.Block

  private var font: Font {
    if let level = block.headingLevel { return level <= 2 ? .headline : .subheadline.weight(.semibold) }
    return block.isCode ? .system(.callout, design: .monospaced) : .callout
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let marker = block.marker {
        Text(verbatim: marker).foregroundStyle(.secondary)
      }
      Text(block.text)
        .font(font)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(block.isCode ? 8 : 0)
    .background(block.isCode ? Color.secondary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
  }
}
