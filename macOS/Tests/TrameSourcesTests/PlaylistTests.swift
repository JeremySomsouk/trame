import Foundation
import Testing

@testable import TrameSources

@Test func relativeChannelsKeepMetadataAndIgnoreDuplicates() throws {
  let text = """
    #EXTM3U
    #EXTINF:-1 group-title="Culture, arts",Cinéma
    films/index.m3u8
    films/index.m3u8
    file:///tmp/private
    """
  let catalog = try PlaylistParser.parse(
    Data(text.utf8), origin: #require(URL(string: "https://example.org/list.m3u")), name: "Liste")
  #expect(catalog.channels.count == 1)
  #expect(catalog.channels.first?.name == "Cinéma")
  #expect(catalog.groups == ["Culture, arts"])
  #expect(catalog.channels.first?.url.absoluteString == "https://example.org/films/index.m3u8")
}

@Test func hlsIsOnePlayableStream() throws {
  let origin = try #require(URL(string: "https://example.org/index.m3u8"))
  let catalog = try PlaylistParser.parse(
    Data("#EXTM3U\n#EXT-X-TARGETDURATION:5\nsegment.ts".utf8), origin: origin, name: "Direct")
  #expect(catalog.channels.map(\.url) == [origin])
}

@Test func invalidPlaylistIsRejected() {
  #expect(throws: ImportError.self) {
    try PlaylistParser.parse(Data("hello".utf8), origin: URL(filePath: "/tmp/list"), name: "")
  }
}

@Test func metadataAllowsQuotedCommasSpacedAssignmentsAndCRLF() throws {
  let text =
    "\u{FEFF}#EXTM3U\r\n#EXTINF:-1 tvg-name = \"Cinéma du soir\" group-title = \"Arts, films\",\r\nflux.m3u8\r\n#EXTGRP:Musique\r\nradio.aac\r\n"
  let catalog = try PlaylistParser.parse(
    Data(text.utf8), origin: #require(URL(string: "https://example.org/tv/list.m3u")), name: "")
  #expect(catalog.channels.map(\.name) == ["Cinéma du soir", "radio.aac"])
  #expect(catalog.channels.map(\.group) == ["Arts, films", "Musique"])
}
