import Foundation
import SwiftUI

class PubMedManager {
    static let shared = PubMedManager()
    
    private let baseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
    private let fetchURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
    
    func fetchRecentPublications(meshTerms: [String], completion: @escaping ([Publication]?, Error?) -> Void) {
        // Guard against empty MeSH terms
        guard !meshTerms.isEmpty else {
            completion([], nil)
            return
        }
        
        // Calculate date 24 hours ago
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dateString = dateFormatter.string(from: yesterday)
        
        // Create mesh term query
        let meshQuery = meshTerms.map { "\"\($0)\"[Mesh]" }.joined(separator: " OR ")
        
        let params: [String: String] = [
            "db": "pubmed",
            "retmode": "json",
            "sort": "pubdate",
            "term": "(\(meshQuery)) AND (\(dateString)[PDAT] : \(dateFormatter.string(from: Date()))[PDAT])"
        ]
        
        var components = URLComponents(string: baseURL)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        let task = URLSession.shared.dataTask(with: components.url!) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }
            
            guard let data = data else {
                completion(nil, NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
                return
            }
            
            do {
                let result = try JSONDecoder().decode(PubMedSearchResult.self, from: data)
                self.fetchPublicationDetails(ids: result.esearchresult.idlist, meshTerms: meshTerms, completion: completion)
            } catch {
                completion(nil, error)
            }
        }
        
        task.resume()
    }
    
    private func fetchPublicationDetails(ids: [String], meshTerms: [String], completion: @escaping ([Publication]?, Error?) -> Void) {
        let idString = ids.joined(separator: ",")
        
        let params: [String: String] = [
            "db": "pubmed",
            "retmode": "xml",
            "rettype": "abstract",
            "id": idString
        ]
        
        var components = URLComponents(string: fetchURL)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        let task = URLSession.shared.dataTask(with: components.url!) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }
            
            guard let data = data else {
                completion(nil, NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
                return
            }
            
            let parser = PubMedXMLParser(data: data, userMeshTerms: meshTerms)
            parser.parse { publications in
                completion(publications, nil)
            }
        }
        
        task.resume()
    }
}

struct PubMedSearchResult: Codable {
    let esearchresult: ESearchResult
    
    struct ESearchResult: Codable {
        let idlist: [String]
    }
}

class PubMedXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var publications: [Publication] = []
    private var currentElement = ""
    private var currentPublication: Publication?
    private var currentAuthors: [Author] = []
    private var currentAuthor: Author?
    private var completion: (([Publication]) -> Void)?
    private var currentMeshTerm: String = ""
    private var currentMeshTerms: [String] = []
    private let userMeshTerms: [String]  // User's selected terms
    private var currentAbstractContent: String = ""
    private var currentTitleContent: String = ""
    private var currentJournalTitle: String = ""
    private var isInAbstract = false
    private var isInTitle = false
    private var isInJournal = false
    
    init(data: Data, userMeshTerms: [String]) {
        self.data = data
        self.userMeshTerms = userMeshTerms
    }
    
    func parse(completion: @escaping ([Publication]) -> Void) {
        self.completion = completion
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        if elementName == "PubmedArticle" {
            currentPublication = Publication(
                id: "",
                title: "",
                abstract: "",
                journal: "",
                firstAuthor: Author(lastName: "", foreName: "", initials: ""),
                lastAuthor: Author(lastName: "", foreName: "", initials: "")
            )
            currentMeshTerms = []
            currentJournalTitle = ""
        } else if elementName == "Author" {
            currentAuthor = Author(lastName: "", foreName: "", initials: "")
        } else if elementName == "DescriptorName" {
            currentMeshTerm = ""
        } else if elementName == "AbstractText" {
            isInAbstract = true
            currentAbstractContent = ""
        } else if elementName == "ArticleTitle" {
            isInTitle = true
            currentTitleContent = ""
        } else if elementName == "Journal" {
            isInJournal = true
        } else if elementName == "Title" && isInJournal {
            // Reset journal title when starting a new journal title element
            currentJournalTitle = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInAbstract {
            currentAbstractContent += string
        } else if isInTitle {
            currentTitleContent += string
        } else if isInJournal && currentElement == "Title" {
            currentJournalTitle += string
        } else {
            let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedString.isEmpty { return }
            
            switch currentElement {
            case "PMID":
                currentPublication?.id.append(trimmedString)
            case "LastName":
                currentAuthor?.lastName.append(trimmedString)
            case "ForeName":
                currentAuthor?.foreName.append(trimmedString)
            case "Initials":
                currentAuthor?.initials.append(trimmedString)
            case "DescriptorName":
                currentMeshTerm.append(trimmedString)
            default:
                break
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "PubmedArticle" {
            if var publication = currentPublication {
                // Ensure we have at least one author
                if !currentAuthors.isEmpty {
                    publication.firstAuthor = currentAuthors.first!
                    
                    // For single-author papers, set lastAuthor = firstAuthor
                    if currentAuthors.count == 1 {
                        publication.lastAuthor = currentAuthors.first!
                    } else {
                        publication.lastAuthor = currentAuthors.last!
                    }
                    
                    publications.append(publication)
                }
            }
            currentPublication = nil
            currentAuthors = []
        } else if elementName == "Author" {
            if let author = currentAuthor {
                currentAuthors.append(author)
            }
            currentAuthor = nil
        } else if elementName == "DescriptorName" {
            currentMeshTerms.append(currentMeshTerm)
            currentMeshTerm = ""
        } else if elementName == "MeshHeadingList" {
            // Find matching terms
            let matched = userMeshTerms.filter { userTerm in
                currentMeshTerms.contains { meshTerm in
                    meshTerm.localizedCaseInsensitiveContains(userTerm)
                }
            }
            currentPublication?.matchedMeshTerms = matched
        } else if elementName == "AbstractText" {
            isInAbstract = false
            currentPublication?.abstract = currentAbstractContent
        } else if elementName == "ArticleTitle" {
            isInTitle = false
            currentPublication?.title = currentTitleContent
        } else if elementName == "Journal" {
            isInJournal = false
        } else if elementName == "Title" && isInJournal {
            currentPublication?.journal = currentJournalTitle
        }
    }
    
    func parserDidEndDocument(_ parser: XMLParser) {
        completion?(publications)
    }
}

struct Publication: Identifiable {
    var id: String
    var title: String
    var abstract: String
    var journal: String
    var firstAuthor: Author
    var lastAuthor: Author
    var matchedMeshTerms: [String] = []
    var url: URL? {
        URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(id)")
    }
    
    var hasAbstract: Bool {
        !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // Convert HTML to Markdown
    var markdownTitle: String {
        HTMLToMarkdownFormatter.convert(html: title)
    }
    
    var markdownAbstract: String {
        HTMLToMarkdownFormatter.convert(html: abstract)
    }
    
    // Clean journal name (remove extra spaces/newline)s
    var cleanedJournal: String {
        journal.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Author {
    var lastName: String
    var foreName: String
    var initials: String
    
    var displayName: String {
        return "\(lastName) \(initials)"
    }
}

struct HTMLToMarkdownFormatter {
    static func convert(html: String) -> String {
        var markdown = html
        /*
        // Replace italics
        markdown = markdown.replacingOccurrences(of: "<i>", with: "*")
                           .replacingOccurrences(of: "</i>", with: "*")
        
        // Replace superscripts
        markdown = markdown.replacingOccurrences(of: "<sup>", with: "^")
                           .replacingOccurrences(of: "</sup>", with: "^")
        
        // Replace subscripts
        markdown = markdown.replacingOccurrences(of: "<sub>", with: "~")
                           .replacingOccurrences(of: "</sub>", with: "~")
        
        // Remove other HTML tags
        markdown = markdown.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        
        /* Handle common HTML entities
        markdown = markdown.replacingOccurrences(of: "&alpha;", with: "α")
                           .replacingOccurrences(of: "&beta;", with: "β")
                           .replacingOccurrences(of: "&gamma;", with: "γ")
                           .replacingOccurrences(of: "&delta;", with: "δ")
                           .replacingOccurrences(of: "&epsilon;", with: "ε")
                           .replacingOccurrences(of: "&zeta;", with: "ζ")
                           .replacingOccurrences(of: "&eta;", with: "η")
                           .replacingOccurrences(of: "&theta;", with: "θ")
                           .replacingOccurrences(of: "&lambda;", with: "λ")
                           .replacingOccurrences(of: "&mu;", with: "μ")
                           .replacingOccurrences(of: "&nu;", with: "ν")
                           .replacingOccurrences(of: "&xi;", with: "ξ")
                           .replacingOccurrences(of: "&pi;", with: "π")
                           .replacingOccurrences(of: "&rho;", with: "ρ")
                           .replacingOccurrences(of: "&sigma;", with: "σ")
                           .replacingOccurrences(of: "&tau;", with: "τ")
                           .replacingOccurrences(of: "&phi;", with: "φ")
                           .replacingOccurrences(of: "&chi;", with: "χ")
                           .replacingOccurrences(of: "&psi;", with: "ψ")
                           .replacingOccurrences(of: "&omega;", with: "ω")
                           .replacingOccurrences(of: "&sup1;", with: "¹")
                           .replacingOccurrences(of: "&sup2;", with: "²")
                           .replacingOccurrences(of: "&sup3;", with: "³")
                           .replacingOccurrences(of: "&sub1;", with: "₁")
                           .replacingOccurrences(of: "&sub2;", with: "₂")
                           .replacingOccurrences(of: "&sub3;", with: "₃")
                           .replacingOccurrences(of: "&plusmn;", with: "±")
                           .replacingOccurrences(of: "&times;", with: "×")
                           .replacingOccurrences(of: "&divide;", with: "÷")
                           .replacingOccurrences(of: "&deg;", with: "°")
                           .replacingOccurrences(of: "&prime;", with: "′")
                           .replacingOccurrences(of: "&Prime;", with: "″")
                           .replacingOccurrences(of: "&micro;", with: "µ")
                           .replacingOccurrences(of: "&middot;", with: "·")
                           .replacingOccurrences(of: "&ndash;", with: "–")
                           .replacingOccurrences(of: "&mdash;", with: "—")
                           .replacingOccurrences(of: "&#xb7;", with: "·")
                           .replacingOccurrences(of: "&#x2013;", with: "–")
                           .replacingOccurrences(of: "&#x2014;", with: "—")
                           .replacingOccurrences(of: "&amp;", with: "&")
                           .replacingOccurrences(of: "&lt;", with: "<")
                           .replacingOccurrences(of: "&gt;", with: ">")
                           .replacingOccurrences(of: "&quot;", with: "\"")
                           .replacingOccurrences(of: "&apos;", with: "'")
        */*/
        return markdown
    }
}

class Settings: ObservableObject {
    @Published var meshTerms: [String] = ["Hematopoietic Stem Cells", "Inflammation", "Proteostasis", "Hematopoiesis", "Clonal Evolution"] {
        didSet {
            saveTerms()
        }
    }
    
    init() {
        loadTerms()
    }
    
    private func saveTerms() {
        UserDefaults.standard.set(meshTerms, forKey: "meshTerms")
    }
    
    private func loadTerms() {
        if let terms = UserDefaults.standard.stringArray(forKey: "meshTerms") {
            meshTerms = terms
        }
    }
}

struct ContentView: View {
    @StateObject private var settings = Settings()
    @State private var publications: [Publication] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingSettings = false
    @State private var needsRefresh = false
    @State private var expandedPublicationID: String? = nil
    
    var body: some View {
        NavigationView {
            Group {
                if settings.meshTerms.isEmpty {
                    VStack {
                        Text("No MeSH terms selected")
                            .font(.title2)
                        Text("Add terms in Settings to see publications")
                            .foregroundColor(.secondary)
                        Button("Open Settings") {
                            showingSettings = true
                        }
                        .padding(.top, 8)
                    }
                } else if isLoading {
                    ProgressView("Loading publications...")
                } else if let error = errorMessage {
                    VStack {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                        Button("Retry") {
                            fetchPublications()
                        }
                    }
                } else if publications.isEmpty {
                    Text("No publications found for the selected MeSH terms in the last 24 hours.")
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List(publications) { publication in
                        PublicationView(
                            publication: publication,
                            isExpanded: expandedPublicationID == publication.id,
                            toggleExpand: {
                                if expandedPublicationID == publication.id {
                                    expandedPublicationID = nil
                                } else {
                                    expandedPublicationID = publication.id
                                }
                            }
                        )
                    }
                }
            }
            .navigationTitle("Fresh PubMed ☕")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingSettings = true
                        needsRefresh = true
                    }) {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: fetchPublications) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                if needsRefresh {
                    fetchPublications()
                    needsRefresh = false
                }
            }) {
                SettingsView(settings: settings)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            fetchPublications()
        }
    }
    
    private func fetchPublications() {
        isLoading = true
        errorMessage = nil
        expandedPublicationID = nil
        
        PubMedManager.shared.fetchRecentPublications(meshTerms: settings.meshTerms) { result, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error {
                    errorMessage = error.localizedDescription
                } else if let result = result {
                    publications = result
                }
            }
        }
    }
}

struct PublicationView: View {
    let publication: Publication
    let isExpanded: Bool
    let toggleExpand: () -> Void
    
    private var shouldShowEllipsis: Bool {
        return !publication.lastAuthor.displayName.isEmpty &&
               publication.lastAuthor.displayName != publication.firstAuthor.displayName
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title section
            HStack(spacing: 4) {
                Text(.init(publication.markdownTitle))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                
                if let url = publication.url {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                }
            }
            
            // Authors section
            HStack(alignment: .firstTextBaseline) {
                Text(publication.firstAuthor.displayName)
                    .font(.subheadline)
                
                if shouldShowEllipsis {
                    Text("...")
                        .font(.subheadline)
                        .padding(.horizontal, 2)
                    
                    Text(publication.lastAuthor.displayName)
                        .font(.subheadline)
                }
            }
            .padding(.top, 4)
            
            // Journal section
            if !publication.cleanedJournal.isEmpty {
                Text(publication.cleanedJournal)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            
            // Matched MeSH terms section
            VStack(alignment: .leading, spacing: 4) {
                if !publication.matchedMeshTerms.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(publication.matchedMeshTerms, id: \.self) { term in
                                Text(term)
                                    .font(.caption)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.05))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.blue, lineWidth: 1)
                                    )
                            }
                        }
                    }
                } else {
                    Text("Related content (hierarchical match)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
            .padding(.top, 4)
            
            // Abstract section
            if publication.hasAbstract {
                Button(action: toggleExpand) {
                    HStack {
                        Text(isExpanded ? "Hide Abstract" : "Show Abstract")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                
                if isExpanded {
                    Text(.init(publication.markdownAbstract))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var newTerm = ""
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Current MeSH Terms")) {
                    ForEach(settings.meshTerms, id: \.self) { term in
                        Text(term)
                    }
                    .onDelete { indices in
                        settings.meshTerms.remove(atOffsets: indices)
                    }
                }
                
                Section(header: Text("Add New Term")) {
                    TextField("Enter MeSH term", text: $newTerm)
                    Button("Add Term") {
                        if !newTerm.isEmpty {
                            settings.meshTerms.append(newTerm)
                            newTerm = ""
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

@main
struct PubMedRecentApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
