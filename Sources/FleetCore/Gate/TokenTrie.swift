import Foundation

/// A prefix tree over every usable token's surface text.
///
/// Built once per vocabulary. Its job is to make "which tokens are legal in this
/// state?" cheap: a depth-first walk that advances the schema automaton one
/// character per trie edge and abandons a subtree the moment the automaton
/// rejects, instead of testing all ~150k tokens against the state.
public final class TokenTrie: @unchecked Sendable {

    final class Node {
        var children: [Unicode.Scalar: Node] = [:]
        /// Token ids whose text ends exactly here.
        var terminals: [Int] = []
    }

    let root = Node()
    public let vocabularySize: Int

    public init(vocabulary: any TokenVocabulary) {
        self.vocabularySize = vocabulary.count
        for id in 0 ..< vocabulary.count {
            guard let text = vocabulary.text(of: id), !text.isEmpty else { continue }
            insert(text, id: id)
        }
    }

    private func insert(_ text: String, id: Int) {
        var node = root
        for scalar in text.unicodeScalars {
            if let next = node.children[scalar] {
                node = next
            } else {
                let next = Node()
                node.children[scalar] = next
                node = next
            }
        }
        node.terminals.append(id)
    }

    /// The longest token that is a prefix of `text`, with the characters it
    /// consumes. Used to emit forced literal runs in as few tokens as possible,
    /// which keeps the decoded token stream close to how the same text was
    /// tokenized during training.
    public func longestPrefix(of text: String) -> (tokenId: Int, consumed: String)? {
        var node = root
        var consumed = String.UnicodeScalarView()
        var best: (tokenId: Int, consumed: String)?
        for scalar in text.unicodeScalars {
            guard let next = node.children[scalar] else { break }
            node = next
            consumed.append(scalar)
            if let id = next.terminals.first {
                best = (id, String(consumed))
            }
        }
        return best
    }

    /// Every token whose full text can be emitted from `state`.
    ///
    /// The reached state is not returned: the caller re-folds the chosen token's
    /// characters through the automaton, which is a handful of steps and avoids
    /// holding a per-token state map for slots where nearly the whole vocabulary
    /// is legal.
    public func admissibleTokens(
        from state: SchemaAutomaton.State,
        in automaton: SchemaAutomaton
    ) -> [Int] {
        var results: [Int] = []
        walk(node: root, state: state, automaton: automaton, results: &results)
        return results
    }

    private func walk(
        node: Node,
        state: SchemaAutomaton.State,
        automaton: SchemaAutomaton,
        results: inout [Int]
    ) {
        results.append(contentsOf: node.terminals)
        for (scalar, child) in node.children {
            guard let next = automaton.advance(state, scalar) else { continue }
            walk(node: child, state: next, automaton: automaton, results: &results)
        }
    }
}
