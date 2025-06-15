//This one works but italics are truncated

import Foundation
import SwiftUI

class PubMedManager {
    static let shared = PubMedManager()
    
    private let baseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
    private let fetchURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
    
    func fetchRecentPublications(meshTerms: [String], completion: @escaping ([Publication]?, Error?) -> Void) {
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
                firstAuthor: Author(lastName: "", foreName: "", initials: ""),
                lastAuthor: Author(lastName: "", foreName: "", initials: "")
            )
            currentMeshTerms = []
        } else if elementName == "Author" {
            currentAuthor = Author(lastName: "", foreName: "", initials: "")
        } else if elementName == "DescriptorName" {
            currentMeshTerm = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedString.isEmpty { return }
        
        switch currentElement {
        case "PMID":
            currentPublication?.id.append(trimmedString)
        case "ArticleTitle":
            currentPublication?.title.append(trimmedString)
        case "AbstractText":
            currentPublication?.abstract.append(trimmedString)
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
        }
        if elementName == "Author" {
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
        } else if elementName == "PubmedArticle" {
            if var publication = currentPublication, !currentAuthors.isEmpty {
                publication.firstAuthor = currentAuthors.first!
                publication.lastAuthor = currentAuthors.last!
                publications.append(publication)
            }
            currentPublication = nil
            currentAuthors = []
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
    var firstAuthor: Author
    var lastAuthor: Author
    var matchedMeshTerms: [String] = []  // Add matched terms property
    var url: URL? {
        URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(id)")
    }
    
    var hasAbstract: Bool {
        !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // Add HTML stripping
    var cleanedTitle: String {
        return title
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: "", options: .regularExpression)
    }
    
    var cleanedAbstract: String {
        return abstract
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: "", options: .regularExpression)
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

// Add HTML stripping extension
extension String {
    func stripHTML() -> String {
        return self
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: "", options: .regularExpression)
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
    @State private var expandedPublicationID: String? = nil  // Track expanded abstract
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
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
                                // Close if already expanded, else expand this one
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
        expandedPublicationID = nil  // Reset expanded state on refresh
        
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
    
    // Add computed property to check if we should show ellipsis
    private var shouldShowEllipsis: Bool {
        // Only show if last author exists AND is different from first author
        return !publication.lastAuthor.displayName.isEmpty &&
               publication.lastAuthor.displayName != publication.firstAuthor.displayName
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title section
            HStack(spacing: 4) {
                Text(publication.cleanedTitle)
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
                
                // Show ellipsis only if there's a last author
                if shouldShowEllipsis {
                    Text("...")
                        .font(.subheadline)
                        .padding(.horizontal, 2)
                    
                    Text(publication.lastAuthor.displayName)
                        .font(.subheadline)
                }
            }
            .padding(.top, 4)
            
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
                    Text(publication.cleanedAbstract)
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
