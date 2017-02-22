module RepositoryHost
  class Bitbucket < Base
    IGNORABLE_EXCEPTIONS = [BitBucket::Error::NotFound, BitBucket::Error::Forbidden]

    def avatar_url(size = 60)
      "https://bitbucket.org/#{repository.full_name}/avatar/#{size}"
    end

    def self.create(full_name, token = nil)
      Repository.create_from_hash(fetch_repo(full_name, token))
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def download_fork_source(token = nil)
      super
      Repository.create_from_bitbucket(repository.source_name, token)
    end

    def download_readme(token = nil)
      user_name, repo_name = repository.full_name.split('/')
      files = api_client(token).repos.sources.list(user_name, repo_name, 'master', '/')
      paths =  files.files.map(&:path)
      readme_path = paths.select{|path| path.match(/^readme/i) }.first
      return if readme_path.nil?
      raw_content = api_client(token).repos.sources.list(user_name, repo_name, 'master', readme_path).data
      contents = {
        html_body: GitHub::Markup.render(readme_path, raw_content)
      }

      if repository.readme.nil?
        repository.create_readme(contents)
      else
        repository.readme.update_attributes(contents)
      end
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def download_tags(token = nil)
      user_name, repo_name = repository.full_name.split('/')
      remote_tags = api_client(token).repos.tags(user_name, repo_name)
      existing_tag_names = repository.tags.pluck(:name)
      remote_tags.each do |name, data|
        next if existing_tag_names.include?(name)
        repository.tags.create({
          name: name,
          kind: "tag",
          sha: data.raw_node,
          published_at: data.utctimestamp
        })
      end
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def update(token = nil)
      begin
        r = self.class.fetch_repo(repository.full_name)
        return unless r.present?
        repository.uuid = r[:id] unless repository.uuid == r[:id]
         if repository.full_name.downcase != r[:full_name].downcase
           clash = Repository.host(r[:host_type]).where('lower(full_name) = ?', r[:full_name].downcase).first
           if clash && (!clash.update_from_repository(token) || clash.status == "Removed")
             clash.destroy
           end
           repository.full_name = r[:full_name]
         end
        repository.owner_id = r[:owner][:id]
        repository.license = Project.format_license(r[:license][:key]) if r[:license]
        repository.source_name = r[:parent][:full_name] if r[:fork]
        repository.assign_attributes r.slice(*Repository::API_FIELDS)
        repository.save! if self.changed?
      rescue BitBucket::Error::NotFound
        repository.update_attribute(:status, 'Removed') if !repository.private?
      rescue *IGNORABLE_EXCEPTIONS
        nil
      end
    end

    private

    def self.api_client(token = nil)
      BitBucket.new oauth_token: token || ENV['BITBUCKET_KEY']
    end

    def api_client(token = nil)
      self.class.api_client(token)
    end

    def self.fetch_repo(full_name, token = nil)
      client = api_client(token)
      user_name, repo_name = full_name.split('/')
      project = client.repos.get(user_name, repo_name)
      v1_project = client.repos.get(user_name, repo_name, api_version: '1.0')
      repo_hash = project.to_hash.with_indifferent_access.slice(:description, :language, :full_name, :name, :has_wiki, :has_issues, :scm)

      repo_hash.merge!({
        id: project.uuid,
        host_type: 'Bitbucket',
        owner: {},
        homepage: project.website,
        fork: project.parent.present?,
        created_at: project.created_on,
        updated_at: project.updated_on,
        subscribers_count: v1_project.followers_count,
        forks_count: v1_project.forks_count,
        private: project.is_private,
        size: project[:size].to_f/1000,
        parent: {
          full_name: project.fetch('parent', {}).fetch('full_name', nil)
        }
      })
    end
  end
end
