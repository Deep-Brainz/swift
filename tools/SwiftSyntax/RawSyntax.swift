//===------------------ RawSyntax.swift - Raw Syntax nodes ----------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

extension CodingUserInfoKey {
  /// Callback that will be called whenever a `RawSyntax` node is decoded
  /// Value must have signature `(RawSyntax) -> Void`
  static let rawSyntaxDecodedCallback =
    CodingUserInfoKey(rawValue: "SwiftSyntax.RawSyntax.DecodedCallback")!
  /// Function that shall be used to look up nodes that were omitted in the
  /// syntax tree transfer.
  /// Value must have signature `(SyntaxNodeId) -> RawSyntax`
  static let omittedNodeLookupFunction =
    CodingUserInfoKey(rawValue: "SwiftSyntax.RawSyntax.OmittedNodeLookup")!
}

/// A ID that uniquely identifies a syntax node and stays stable across multiple
/// incremental parses
struct SyntaxNodeId: Hashable, Codable {
  private let rawValue: UInt

  fileprivate init(rawValue: UInt) {
    self.rawValue = rawValue
  }

  init(from decoder: Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(UInt.self)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Represents the raw tree structure underlying the syntax tree. These nodes
/// have no notion of identity and only provide structure to the tree. They
/// are immutable and can be freely shared between syntax nodes.
indirect enum RawSyntax: Codable {
  /// A tree node with a kind, an array of children, and a source presence.
  case node(SyntaxKind, [RawSyntax?], SourcePresence, SyntaxNodeId?)

  /// A token with a token kind, leading trivia, trailing trivia, and a source
  /// presence.
  case token(TokenKind, Trivia, Trivia, SourcePresence, SyntaxNodeId?)

  /// The syntax kind of this raw syntax.
  var kind: SyntaxKind {
    switch self {
    case .node(let kind, _, _, _): return kind
    case .token(_, _, _, _, _): return .token
    }
  }

  var tokenKind: TokenKind? {
    switch self {
    case .node(_, _, _, _): return nil
    case .token(let kind, _, _, _, _): return kind
    }
  }

  /// The layout of the children of this Raw syntax node.
  var layout: [RawSyntax?] {
    switch self {
    case .node(_, let layout, _, _): return layout
    case .token(_, _, _, _, _): return []
    }
  }

  /// The source presence of this node.
  var presence: SourcePresence {
    switch self {
    case .node(_, _, let presence, _): return presence
    case .token(_, _, _, let presence, _): return presence
    }
  }

  /// The ID of this node
  var id: SyntaxNodeId? {
    switch self {
    case .node(_, _, _, let id): return id
    case .token(_, _, _, _, let id): return id
    }
  }

  /// Whether this node is present in the original source.
  var isPresent: Bool {
    return presence == .present
  }

  /// Whether this node is missing from the original source.
  var isMissing: Bool {
    return presence == .missing
  }

  /// Keys for serializing RawSyntax nodes.
  enum CodingKeys: String, CodingKey {
    // Shared keys
    case id, omitted

    // Keys for the `node` case
    case kind, layout, presence
    
    // Keys for the `token` case
    case tokenKind, leadingTrivia, trailingTrivia
  }

  public enum IncrementalDecodingError: Error {
    /// The JSON to decode is invalid because a node had the `omitted` flag set
    /// but included no id
    case omittedNodeHasNoId
    /// An omitted node was encountered but no node lookup function was
    /// in the decoder's `userInfo` for the `.omittedNodeLookupFunction` key
    /// or the lookup function had the wrong type
    case noLookupFunctionPassed
    /// A node with the given ID was omitted from the tranferred syntax tree
    /// but the lookup function was unable to look it up
    case nodeLookupFailed(SyntaxNodeId)
  }

  /// Creates a RawSyntax from the provided Foundation Decoder.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decodeIfPresent(SyntaxNodeId.self, forKey: .id)
    let omitted = try container.decodeIfPresent(Bool.self, forKey: .omitted) ?? false

    if omitted {
      guard let id = id else {
        throw IncrementalDecodingError.omittedNodeHasNoId
      }
      guard let lookupFunc = decoder.userInfo[.omittedNodeLookupFunction] as?
                               (SyntaxNodeId) -> RawSyntax? else {
        throw IncrementalDecodingError.noLookupFunctionPassed
      }
      guard let lookupNode = lookupFunc(id) else {
        throw IncrementalDecodingError.nodeLookupFailed(id)
      }
      self = lookupNode
      return
    }

    let presence = try container.decode(SourcePresence.self, forKey: .presence)
    if let kind = try container.decodeIfPresent(SyntaxKind.self, forKey: .kind) {
      let layout = try container.decode([RawSyntax?].self, forKey: .layout)
      self = .node(kind, layout, presence, id)
    } else {
      let kind = try container.decode(TokenKind.self, forKey: .tokenKind)
      let leadingTrivia = try container.decode(Trivia.self, forKey: .leadingTrivia)
      let trailingTrivia = try container.decode(Trivia.self, forKey: .trailingTrivia)
      self = .token(kind, leadingTrivia, trailingTrivia, presence, id)
    }
    if let callback = decoder.userInfo[.rawSyntaxDecodedCallback] as?
                        (RawSyntax) -> Void {
      callback(self)
    }
  }

  /// Encodes the RawSyntax to the provided Foundation Encoder.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .node(kind, layout, presence, id):
      if let id = id {
        try container.encode(id, forKey: .id)
      }
      try container.encode(kind, forKey: .kind)
      try container.encode(layout, forKey: .layout)
      try container.encode(presence, forKey: .presence)
    case let .token(kind, leadingTrivia, trailingTrivia, presence, id):
      if let id = id {
        try container.encode(id, forKey: .id)
      }
      try container.encode(kind, forKey: .tokenKind)
      try container.encode(leadingTrivia, forKey: .leadingTrivia)
      try container.encode(trailingTrivia, forKey: .trailingTrivia)
      try container.encode(presence, forKey: .presence)
    }
  }

  /// Creates a RawSyntax node that's marked missing in the source with the
  /// provided kind and layout.
  /// - Parameters:
  ///   - kind: The syntax kind underlying this node.
  ///   - layout: The children of this node.
  /// - Returns: A new RawSyntax `.node` with the provided kind and layout, with
  ///            `.missing` source presence.
  static func missing(_ kind: SyntaxKind) -> RawSyntax {
    return .node(kind, [], .missing, nil)
  }

  /// Creates a RawSyntax token that's marked missing in the source with the
  /// provided kind and no leading/trailing trivia.
  /// - Parameter kind: The token kind.
  /// - Returns: A new RawSyntax `.token` with the provided kind, no
  ///            leading/trailing trivia, and `.missing` source presence.
  static func missingToken(_ kind: TokenKind) -> RawSyntax {
    return .token(kind, [], [], .missing, nil)
  }

  /// Returns a new RawSyntax node with the provided layout instead of the
  /// existing layout.
  /// - Note: This function does nothing with `.token` nodes --- the same token
  ///         is returned.
  /// - Parameter newLayout: The children of the new node you're creating.
  func replacingLayout(_ newLayout: [RawSyntax?]) -> RawSyntax {
    switch self {
    case let .node(kind, _, presence, _):
      return .node(kind, newLayout, presence, nil)
    case .token(_, _, _, _, _): return self
    }
  }

  /// Creates a new RawSyntax with the provided child appended to its layout.
  /// - Parameter child: The child to append
  /// - Note: This function does nothing with `.token` nodes --- the same token
  ///         is returned.
  /// - Return: A new RawSyntax node with the provided child at the end.
  func appending(_ child: RawSyntax) -> RawSyntax {
    var newLayout = layout
    newLayout.append(child)
    return replacingLayout(newLayout)
  }

  /// Returns the child at the provided cursor in the layout.
  /// - Parameter index: The index of the child you're accessing.
  /// - Returns: The child at the provided index.
  subscript<CursorType: RawRepresentable>(_ index: CursorType) -> RawSyntax?
    where CursorType.RawValue == Int {
      return layout[index.rawValue]
  }

  /// Replaces the child at the provided index in this node with the provided
  /// child.
  /// - Parameters:
  ///   - index: The index of the child to replace.
  ///   - newChild: The new child that should occupy that index in the node.
  func replacingChild(_ index: Int,
                      with newChild: RawSyntax) -> RawSyntax {
    precondition(index < layout.count, "Cursor \(index) reached past layout")
    var newLayout = layout
    newLayout[index] = newChild
    return replacingLayout(newLayout)
  }
}

extension RawSyntax: TextOutputStreamable {
  /// Prints the RawSyntax node, and all of its children, to the provided
  /// stream. This implementation must be source-accurate.
  /// - Parameter stream: The stream on which to output this node.
  func write<Target>(to target: inout Target)
    where Target: TextOutputStream {
    switch self {
    case .node(_, let layout, _, _):
      for child in layout {
        guard let child = child else { continue }
        child.write(to: &target)
      }
    case let .token(kind, leadingTrivia, trailingTrivia, presence, _):
      guard case .present = presence else { return }
      for piece in leadingTrivia {
        piece.write(to: &target)
      }
      target.write(kind.text)
      for piece in trailingTrivia {
        piece.write(to: &target)
      }
    }
  }
}

extension RawSyntax {
  func accumulateAbsolutePosition(_ pos: AbsolutePosition) {
    switch self {
    case .node(_, let layout, _, _):
      for child in layout {
        guard let child = child else { continue }
        child.accumulateAbsolutePosition(pos)
      }
    case let .token(kind, leadingTrivia, trailingTrivia, presence, _):
      guard case .present = presence else { return }
      for piece in leadingTrivia {
        piece.accumulateAbsolutePosition(pos)
      }
      pos.add(text: kind.text)
      for piece in trailingTrivia {
        piece.accumulateAbsolutePosition(pos)
      }
    }
  }

  var leadingTrivia: Trivia? {
    switch self {
    case .node(_, let layout, _, _):
      for child in layout {
        guard let child = child else { continue }
        guard let result = child.leadingTrivia else { continue }
        return result
      }
      return nil
    case let .token(_, leadingTrivia, _, presence, _):
      guard case .present = presence else { return nil }
      return leadingTrivia
    }
  }

  var trailingTrivia: Trivia? {
    switch self {
    case .node(_, let layout, _, _):
      for child in layout.reversed() {
        guard let child = child else { continue }
        guard let result = child.trailingTrivia else { continue }
        return result
      }
      return nil
    case let .token(_, _, trailingTrivia, presence, _):
      guard case .present = presence else { return nil }
      return trailingTrivia
    }
  }

  func accumulateLeadingTrivia(_ pos: AbsolutePosition) {
    guard let trivia = leadingTrivia else { return }
    for piece in trivia {
      piece.accumulateAbsolutePosition(pos)
    }
  }

  func accumulateTrailingTrivia(_ pos: AbsolutePosition) {
    guard let trivia = trailingTrivia else { return }
    for piece in trivia {
      piece.accumulateAbsolutePosition(pos)
    }
  }
}
