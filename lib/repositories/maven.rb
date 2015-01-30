class Repositories
  class Maven < Base
    HAS_VERSIONS = true
    HAS_DEPENDENCIES = true
    URL = 'http://maven.org'

    def self.load_names
      num = REDIS.get('maven-page')
      if num.nil?
        REDIS.set 'maven-page', 41753
        num = 41753
      else
        num = num.to_i
      end

      (1..num).to_a.reverse.each do |number|
        page = Repositories::Maven.get_html "https://maven-repository.com/artifact/latest?page=#{number}"
        page.css('tr')[1..-1].each do |tr|
          REDIS.sadd 'maven-names', tr.css('td')[0..1].map(&:text).join(':')
        end
        REDIS.set 'maven-page', number
      end
    end

    def self.project_names
      REDIS.smembers 'maven-names'
    end

    def self.project(name)
      h = {
        name: name,
        path: name.split(':').join('/')
      }
      h[:versions] = versions(h)
      h
    end

    def self.mapping(project)
      latest_version = get_html("https://maven-repository.com/artifact/#{project[:path]}/#{project[:versions][0][:number]}")
      hash = {}
      latest_version.css('tr').each do |tr|
        tds = tr.css('td')
        hash[tds[0].text.gsub(/[^a-zA-Z0-9\s]/,'')] = tds[1] if tds.length == 2
      end
      {
        name: project[:name],
        description: hash['Description'].try(:text),
        homepage: hash['URL'].try(:css,'a').try(:text),
        repository_url: hash['Connection'].try(:text),
        licenses: hash['Name'].try(:text)
      }
    end

    def self.versions(project)
      # multiple verion pages
      page = get_html("https://maven-repository.com/artifact/#{project[:path]}/")
      page.css('tr')[1..-1].map do |tr|
        tds = tr.css('td')
        {
          :number => tds[0].text,
          :published_at => tds[2].text
        }
      end
    end
  end
end
