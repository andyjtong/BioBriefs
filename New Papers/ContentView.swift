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
                self.fetchPublicationDetails(ids: result.esearchresult.idlist, completion: completion)
            } catch {
                completion(nil, error)
            }
        }
        
        task.resume()
    }
    
    private func fetchPublicationDetails(ids: [String], completion: @escaping ([Publication]?, Error?) -> Void) {
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
            
            let parser = PubMedXMLParser(data: data)
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
    
    init(data: Data) {
        self.data = data
    }
    
    func parse(completion: @escaping ([Publication]) -> Void) {
        self.completion = completion
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    // XMLParserDelegate methods
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        if elementName == "PubmedArticle" {
            currentPublication = Publication(id: "", title: "", abstract: "", firstAuthor: Author(lastName: "", foreName: "", initials: ""), lastAuthor: Author(lastName: "", foreName: "", initials: ""))
        } else if elementName == "Author" {
            currentAuthor = Author(lastName: "", foreName: "", initials: "")
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedString.isEmpty { return }
        
        switch currentElement {
        case "PMID":
            currentPublication?.id += trimmedString
        case "ArticleTitle":
            currentPublication?.title += trimmedString
        case "AbstractText":
            currentPublication?.abstract += trimmedString
        case "LastName":
            currentAuthor?.lastName += trimmedString
        case "ForeName":
            currentAuthor?.foreName += trimmedString
        case "Initials":
            currentAuthor?.initials += trimmedString
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Author" {
            if let author = currentAuthor {
                currentAuthors.append(author)
            }
            currentAuthor = nil
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
    var url: URL? {
        URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(id)")
    }
    
    // Add this computed property
    var hasAbstract: Bool {
        !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        PublicationView(publication: publication)
                    }
                    .refreshable {
                        fetchPublications()
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
        .onAppear {
            fetchPublications()
        }
    }
    
    private func fetchPublications() {
        isLoading = true
        errorMessage = nil
        
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
    @State private var showAbstract = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title without link wrapping
            HStack(spacing: 4) {
                Text(publication.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
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
            
            // Authors
            HStack {
                Text("\(publication.firstAuthor.displayName) ...")
                    .font(.subheadline)
                Text("\(publication.lastAuthor.displayName)")
                    .font(.subheadline)
            }
            .padding(.top, 4)
            
            // Show More button and abstract
            if publication.hasAbstract {
                Button(action: {
                    withAnimation {
                        showAbstract.toggle()
                    }
                }) {
                    HStack {
                        Text(showAbstract ? "Show Less" : "Show Abstract")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        
                        Image(systemName: showAbstract ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                
                if showAbstract {
                    Text(publication.abstract)
                        .font(.body)
                        .foregroundColor(.secondary)
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
