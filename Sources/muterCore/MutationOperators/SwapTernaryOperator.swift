import SwiftSyntax

enum SwapTernaryOperator {
    final class Visitor: MuterVisitor {
        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            regionsWithoutCoverage: [Region] = []
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .swapTernary,
                regionsWithoutCoverage: regionsWithoutCoverage
            )
        }

        override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
            guard !node.containsComplexCauses else {
                return super.visit(node)
            }

            let mutatedSyntax = mutated(node)
            let position = endLocation(for: node)
            let snapshot = MutationOperator.Snapshot(
                before: node.description.trimmed.inlined,
                after: mutatedSyntax.description.trimmed.inlined,
                description: "swapped ternary operator"
            )

            add(
                mutation: mutated(node),
                with: node,
                at: position,
                snapshot: snapshot
            )

            return super.visit(node)
        }

        override func visit(_ node: ExprListSyntax) -> SyntaxVisitorContinueKind {
            guard containsTernayExpression(node) else {
                return super.visit(node)
            }

            guard !containsComplexExpressions(cast(node)),
                  let mutatedSyntax = mutated(node)
            else {
                return super.visit(node)
            }

            let position = endLocation(for: node)
            let snapshot = MutationOperator.Snapshot(
                before: node.description.trimmed.inlined,
                after: mutatedSyntax.description.trimmed.inlined,
                description: "swapped ternary operator"
            )

            add(
                mutation: mutatedSyntax,
                with: node,
                at: position,
                snapshot: snapshot
            )

            return super.visit(node)
        }

        private func mutated(_ node: TernaryExprSyntax) -> ExprSyntax {
            ExprSyntax(
                TernaryExprSyntax(
                    leadingTrivia: node.leadingTrivia,
                    condition: node.condition,
                    questionMark: node.questionMark,
                    thenExpression: node.elseExpression,
                    colon: node.colon,
                    elseExpression: node.thenExpression,
                    trailingTrivia: node.trailingTrivia
                )
            )
        }

        /// `nil` when there is no ternary this operator can safely swap, so no mutant is emitted.
        private func mutated(_ node: ExprListSyntax) -> ExprListSyntax? {
            var children = cast(node)
            guard children.contains(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
                  let index = ternaryIndex(node),
                  let ternary = children[index].as(UnresolvedTernaryExprSyntax.self)
            else {
                return nil
            }

            // Only swap when the else-expression is a SINGLE trailing child (`… ? a : b`, so the
            // ternary is at `index` and `b` at `index + 1`, the last element). When the else-expression
            // is itself a comparison/sequence (`… ? a : c < d`), SwiftSyntax flattens `c < d` into
            // multiple sibling children of the outer SequenceExpr; swapping would take only `c` and
            // leave `< d` dangling, producing `x < y < d` — adjacent operators in a non-associative
            // precedence group, a compile error. Emit no mutant rather than invalid code.
            guard children.count == index + 2 else {
                return nil
            }

            let secondChoice = children[index + 1]
                .withTrailingTrivia(.spaces(1))
                .withLeadingTrivia(.spaces(1))
            let firstChoice = ternary.thenExpression
                .withTrailingTrivia(.spaces(1))
                .withLeadingTrivia(.spaces(1))

            children[index] = ExprSyntax(
                UnresolvedTernaryExprSyntax(thenExpression: secondChoice)
                    .withTrailingTrivia(.spaces(1))
                    .withLeadingTrivia(.spaces(1))
            )
            children[index + 1] = firstChoice

            return ExprListSyntax(children)
        }

        private func ternaryIndex(_ node: ExprListSyntax) -> Int? {
            for (index, child) in node.allChildren.enumerated() {
                if child.is(UnresolvedTernaryExprSyntax.self) {
                    return index
                }
            }

            return nil
        }

        private func cast(_ node: ExprListSyntax) -> [ExprSyntax] {
            node.allChildren.compactMap {
                $0.as(ExprSyntax.self)
            }
        }

        private func containsComplexExpressions(_ nodes: [ExprSyntax]) -> Bool {
            nodes.contains(where: { $0.is(AsExprSyntax.self) })
                || nodes.contains(where: { $0.is(UnresolvedAsExprSyntax.self) })
        }

        private func containsTernayExpression(_ node: ExprListSyntax) -> Bool {
            node
                .allChildren
                .containsSyntaxKind(UnresolvedTernaryExprSyntax.self)
        }
    }
}

private extension TernaryExprSyntax {
    var containsComplexCauses: Bool {
        thenExpression.allChildren.containsSyntaxKind(AsExprSyntax.self)
            || elseExpression.allChildren.containsSyntaxKind(AsExprSyntax.self)
    }
}
