import Testing
@testable import RCSPACFileParser

@Test
func maskingBlanksOutLineComments() {
    let source = Array("// hello FindProxyForURL(\ncode")
    let masked = PACSourceInstrumentation.maskCommentsAndStrings(source)
    #expect(masked.count == source.count)
    let maskedString = String(masked)
    #expect(!maskedString.contains("FindProxyForURL"))
    #expect(maskedString.hasSuffix("\ncode"))
    #expect(maskedString.prefix(while: { $0 == " " }).count == source.count - "\ncode".count)
}

@Test
func maskingBlanksOutBlockCommentsPreservingNewlines() {
    let source = Array("/* line1\nline2 */code")
    let masked = PACSourceInstrumentation.maskCommentsAndStrings(source)
    #expect(masked.count == source.count)
    let maskedString = String(masked)
    #expect(!maskedString.contains("line1"))
    #expect(!maskedString.contains("line2"))
    #expect(maskedString.hasSuffix("code"))
    // The newline inside the block comment must be preserved so later line
    // counting (instrumentReturns) stays in sync with the original source.
    #expect(maskedString.filter { $0 == "\n" }.count == 1)
}

@Test
func maskingBlanksOutStringContents() {
    let source = Array(#"return "FindProxyForURL(";"#)
    let masked = PACSourceInstrumentation.maskCommentsAndStrings(source)
    #expect(masked.count == source.count)
    let maskedString = String(masked)
    #expect(!maskedString.contains("FindProxyForURL"))
    #expect(maskedString.hasPrefix("return "))
    #expect(maskedString.hasSuffix(";"))
}

@Test
func locateFindsFunctionDeclarationNotInsideComment() {
    let source = """
    // function FindProxyForURL(old, host) { return "PROXY old:8080"; }
    function FindProxyForURL(url, host) {
      return "DIRECT";
    }
    """
    let masked = PACSourceInstrumentation.maskCommentsAndStrings(Array(source))
    let start = PACSourceInstrumentation.locateFindProxyParamsStart(masked)
    #expect(start != nil)
    if let start {
        let after = String(masked[start...].prefix(20))
        #expect(after.contains("url, host"))
    }
}

@Test
func findMatchingBraceSkipsBracesInStringsAndComments() {
    let source = Array(#"{ if (x) { return "}"; } /* } */ }"#)
    let close = PACSourceInstrumentation.findMatchingBrace(source, openIndex: 0)
    #expect(close == source.count - 1)
}

@Test
func instrumentReturnsWrapsExpressionAndTracksLine() {
    let body = Array("\n  return \"DIRECT\";\n")
    let result = PACSourceInstrumentation.instrumentReturns(body, startLine: 5)
    #expect(result.hitLines == [6])
    let code = String(result.code)
    #expect(code.contains("__trace(6, (\"DIRECT\"))"))
}

@Test
func instrumentReturnsHandlesBareReturn() {
    let body = Array("return;")
    let result = PACSourceInstrumentation.instrumentReturns(body, startLine: 1)
    #expect(result.hitLines == [1])
    #expect(String(result.code) == "return__trace(1, undefined);")
}
