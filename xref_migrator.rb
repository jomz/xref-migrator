# Make sure to set an email address where Crossref can contact you.
# This makes your requests go to the 'polite pool', which should mean
# better performance and better rate limits.
# See https://api.crossref.org/swagger-ui/index.html
contact_email = "you@example.com"

# Add your CSV input files to the 'input' directory.
# The CSV file lists one pair of 'DOI,new URL' per line, see input.example.csv.
# These DOI use the current, soon-to-be-old prefix.
@old_prefix = '10.nnnnn'
@new_prefix = '10.nnnnn'

@depositor_name = 'Your name'
@depositor_email = contact_email
@registrant_name = 'Your organisation'

require 'serrano'
require 'csv'
require 'builder'

Serrano.configuration do |config|
  config.mailto = contact_email
end

def get_doi_metadata(doi)
  puts "Looking up DOI metadata for #{doi}..."
  # I thought ideally we'd use Serrano.registration_agency to figure out where
  # to obtain the metadata, but (at least in our case) this was unreliable.
  # E.g. agency for all our DOIs returned as medra,
  # but a large part of our DOI seemed to actually be at Crossref...
  # Hence, the strategy then became; try to obtain metadata from Crossref,
  # and if that fails with a 404, try again at mEDRA
  begin
    crossref_metadata = Serrano.works(ids: doi).first['message']
    data = {
      journal: {
        full_title: crossref_metadata['container-title'].first,
        publisher: crossref_metadata['publisher'],
        issn: crossref_metadata['ISSN'].first
      },
      article: {
        volume: crossref_metadata['volume'],
        issue: crossref_metadata['issue'],
        title: crossref_metadata['title'].first,
        first_page: crossref_metadata['page'].split('-')[0],
        last_page: crossref_metadata['page'].split('-')[1],
        authors: crossref_metadata['author'].map{
          |author| {
            family: author['family'],
            given: author['given']
          }
        },
        resource_url: crossref_metadata['resource']['primary']['URL'],
        published: {
          year: crossref_metadata['published']['date-parts'][0][0],
          month: crossref_metadata['published']['date-parts'][0][1],
          day: crossref_metadata['published']['date-parts'][0][2]
        },
        published_online: {
          year: crossref_metadata['published-online']['date-parts'][0][0],
          month: crossref_metadata['published-online']['date-parts'][0][1],
          day: crossref_metadata['published-online']['date-parts'][0][2]
        },
        abstract: crossref_metadata['abstract']
      }
    }
  rescue Serrano::NotFound
    puts "DOI #{doi} not found at Crossref, trying mEDRA"
    medra_response = Faraday.new("https://api.medra.org/metadata/#{doi}").get
    if medra_response.status == 404
      puts "mEDRA search for #{doi} failed as well. :("
      @failed_doi << doi
      return nil
    else
      doc = REXML::Document.new(medra_response.body)
      # Our legacy data had some entries where multiple authors were comma separated
      # into one author element. Fixing those first;
      authors = []
      doc.root.get_elements('//Contributor//PersonName').each do |n|
        n.get_text.to_s.split(',').each do |c|
          authors << {family: c.strip}
        end
      end
      data = {
        journal: {
          full_title: doc.root.get_elements('//SerialWork//TitleText').first.get_text,
          publisher: doc.root.get_elements('//SerialWork//PublisherName').first.get_text,
          issn: doc.root.get_elements('//SerialVersion//IDValue').first.get_text
        },
        article: {
          volume: doc.root.get_elements('//JournalIssueDesignation').first.get_text,
          issue: doc.root.get_elements('//JournalIssueNumber').first.get_text,
          title: doc.root.get_elements('//ContentItem//Title//TitleText').first.get_text,
          first_page: doc.root.get_elements('//FirstPageNumber').first.get_text,
          last_page: doc.root.get_elements('//LastPageNumber').first.get_text,
          authors: authors,
          resource_url: doc.root.get_elements('//DOIWebsiteLink').first.get_text,
          published: {
            year: doc.root.get_elements('//JournalIssueDate//Date').first.get_text
          },
          published_online: {
            year: doc.root.get_elements('//JournalIssueDate//Date').first.get_text
          }
        }
      }
    end
  end
end

def build_xrefxml_from_articles_data(articles)
  volume, issue = articles.first[:article][:volume], articles.first[:article][:issue]
  batch_id = "#{volume}.#{issue}"

  Builder::XmlMarkup.new(indent: 2).doi_batch(version: '5.3.1',
    :xmlns => "http://www.crossref.org/schema/5.3.1",
    :"xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance",
    :"xsi:schemaLocation" => "http://www.crossref.org/schema/5.3.1 https://www.crossref.org/schemas/crossref5.3.1.xsd",
    :"xmlns:jats" => "http://www.ncbi.nlm.nih.gov/JATS1",
    :"xmlns:fr" => "http://www.crossref.org/fundref.xsd",
    :"xmlns:mml" => "http://www.w3.org/1998/Math/MathML"
    ) do |build|
    build.head do |h|
      h.doi_batch_id(batch_id)
      h.timestamp(Time.now.strftime("%Y%m%d%H%M%S"))
      h.depositor do |d|
        d.depositor_name(@depositor_name)
        d.email_address(@depositor_email)
      end
      h.registrant(@registrant_name)
    end
    build.body do |b|
      b.journal do |j|
        j.journal_metadata(reference_distribution_opts: 'any') do |jmd|
          jmd.full_title(articles.first[:journal][:full_title])
          jmd.issn(articles.first[:journal][:issn])
        end
        j.journal_issue do |ji|
          ji.publication_date do |pd|
            pd.month(articles.first[:article][:published][:month]) unless articles.first[:article][:published][:month].nil?
            pd.day(articles.first[:article][:published][:day]) unless articles.first[:article][:published][:day].nil?
            pd.year(articles.first[:article][:published][:year])
          end
          ji.issue(issue)
        end
        articles.each do |article|
          j.journal_article do |ja|
            ja.titles do |t|
              t.title(article[:article][:title])
            end
            if article[:article][:authors].length > 0
              ja.contributors do |c|
                article[:article][:authors].each do |author|
                  first = (author == article[:article][:authors].first) ? 'first' : 'additional'
                  c.person_name(sequence: first, contributor_role: 'author') do |pn|
                    pn.surname(author[:family])
                    pn.given_name(author[:given]) unless author[:given].nil?
                  end
                end
              end
            end
            ja.publication_date do |pd|
              pd.month(article[:article][:published][:month]) unless article[:article][:published][:month].nil?
              pd.day(article[:article][:published][:day]) unless article[:article][:published][:day].nil?
              pd.year(article[:article][:published][:year])
            end
            ja.pages do |p|
              p.first_page(article[:article][:first_page])
              p.last_page(article[:article][:last_page]) unless article[:article][:last_page].nil?
            end
            ja.doi_data do |d|
              d.doi(article[:article][:doi])
              d.resource(article[:article][:resource_url])
            end
            ja.jats :abstract do
              article[:article][:abstract]
            end unless article[:article][:abstract].nil?
          end
        end
      end
    end
  end
end

volumes = {}
@failed_doi =  []
@processed_doi = []

Dir.foreach('input') do |filename|
  next if File.directory? filename
  puts "Processing #{filename}..."
  csv_entries = CSV.read("input/#{filename}")
  csv_entries.each do |csv_entry|
    old_doi, new_url = csv_entry[0], csv_entry[1]
    data = get_doi_metadata(old_doi)
    next if data.nil?
    data[:article].merge!(
      resource_url: new_url,
      doi: old_doi.gsub(old_doi.split('/').first, @new_prefix)
    )
    # puts data.to_s
    volume = data[:article][:volume].to_s
    issue = data[:article][:issue].to_s
    volumes[volume] ||= {}
    volumes[volume][issue] ||= []
    volumes[volume][issue] << data
  end
  volumes.each do |volume, issues|
    issues.each do |issue, articles|
      output_filename = "#{volume}-#{issue}-articles.xml"
      xml = build_xrefxml_from_articles_data(articles)
      File.write("output/#{output_filename}", xml)
      @processed_doi.concat articles.map{|a| a[:article][:doi].split("/")[1] }.uniq
    end
  end

  unless @processed_doi.empty?
    File.write(
      "output/transfer_list.tsv", 
      @processed_doi.map{ |d| 
        "#{@old_prefix}/#{d}\t#{@new_prefix}/#{d}" 
      }.join("\n")
    )
  end

  unless @failed_doi.empty?
    File.write("output/failed_doi.txt", @failed_doi.join("\n"))
  end
end
