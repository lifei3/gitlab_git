# Gitlab::Git::Commit is a wrapper around native Grit::Repository object
# We dont want to use grit objects inside app/
# It helps us easily migrate to rugged in future
require_relative 'encoding_herlper'
require 'tempfile'

module Gitlab
  module Git
    class Repository
      include Gitlab::Git::Popen

      class NoRepository < StandardError; end

      # Default branch in the repository
      attr_accessor :root_ref

      # Full path to repo
      attr_reader :path

      # Directory name of repo
      attr_reader :name

      # Grit repo object
      attr_reader :grit

      # Rugged repo object
      attr_reader :rugged

      def initialize(path)
        @path = path
        @name = path.split("/").last
        @root_ref = discover_default_branch
      end

      def grit
        @grit ||= Grit::Repo.new(path)
      rescue Grit::NoSuchPathError
        raise NoRepository.new('no repository for such path')
      end

      # Alias to old method for compatibility
      def raw
        grit
      end

      def rugged
        @rugged ||= Rugged::Repository.new(path)
      rescue Rugged::RepositoryError, Rugged::OSError
        raise NoRepository.new('no repository for such path')
      end

      # Returns an Array of branch names
      # sorted by name ASC
      def branch_names
        branches.map(&:name)
      end

      # Returns an Array of Branches
      def branches
        rugged.branches.map do |rugged_ref|
          Branch.new(rugged_ref.name, rugged_ref.target)
        end.sort_by(&:name)
      end

      # Returns an Array of tag names
      def tag_names
        rugged.tags.map { |t| t.name }
      end

      # Returns an Array of Tags
      def tags
        rugged.refs.select do |ref|
          ref.name =~ /\Arefs\/tags/
        end.map do |rugged_ref|
          Tag.new(rugged_ref.name, rugged_ref.target)
        end.sort_by(&:name)
      end

      # Returns an Array of branch and tag names
      def ref_names
        branch_names + tag_names
      end

      # Deprecated. Will be removed in 5.2
      def heads
        @heads ||= grit.heads.sort_by(&:name)
      end

      def has_commits?
        !empty?
      end

      def empty?
        rugged.empty?
      end

      def repo_exists?
        !!rugged
      end

      # Discovers the default branch based on the repository's available branches
      #
      # - If no branches are present, returns nil
      # - If one branch is present, returns its name
      # - If two or more branches are present, returns current HEAD or master or first branch
      def discover_default_branch
        if branch_names.length == 0
          nil
        elsif branch_names.length == 1
          branch_names.first
        elsif rugged_head && branch_names.include?(Ref.extract_branch_name(rugged_head.name))
          Ref.extract_branch_name(rugged_head.name)
        elsif branch_names.include?("master")
          "master"
        else
          branch_names.first
        end
      end

      def rugged_head
        rugged.head
      rescue Rugged::ReferenceError
        nil
      end

      # Archive Project to .tar.gz
      #
      # Already packed repo archives stored at
      # app_root/tmp/repositories/project_name/project_name-commit-id.tag.gz
      #
      def archive_repo(ref, storage_path, format = "tar.gz")
        ref = ref || self.root_ref
        commit = Gitlab::Git::Commit.find(self, ref)
        return nil unless commit

        extension = nil
        git_archive_format = nil
        pipe_cmd = nil

        case format
        when "tar.bz2", "tbz", "tbz2", "tb2", "bz2"
          extension = ".tar.bz2"
          pipe_cmd = %W(bzip2)
        when "tar"
          extension = ".tar"
          pipe_cmd = %W(cat)
        when "zip"
          extension = ".zip"
          git_archive_format = "zip"
          pipe_cmd = %W(cat)
        else
          # everything else should fall back to tar.gz
          extension = ".tar.gz"
          git_archive_format = nil
          pipe_cmd = %W(gzip -n)
        end

        # Build file path
        file_name = self.name.gsub("\.git", "") + "-" + commit.id.to_s + extension
        file_path = File.join(storage_path, self.name, file_name)

        # Put files into a directory before archiving
        prefix = File.basename(self.name) + "/"

        # Create file if not exists
        unless File.exists?(file_path)
          # create archive in temp file
          tmp_file = Tempfile.new('gitlab-archive-repo', storage_path)
          self.grit.archive_to_file(ref, prefix, tmp_file.path, git_archive_format, pipe_cmd)

          # move temp file to persisted location
          FileUtils.mkdir_p File.dirname(file_path)
          FileUtils.move(tmp_file.path, file_path)

          # delte temp file
          tmp_file.close
          tmp_file.unlink
        end

        file_path
      end

      # Return repo size in megabytes
      def size
        size = popen(%W(du -s), path).first.strip.to_i
        (size.to_f / 1024).round(2)
      end

      def search_files(query, ref = nil)
        if ref.nil? || ref == ""
          ref = root_ref
        end

        greps = grit.grep(query, 3, ref)

        greps.map do |grep|
          Gitlab::Git::BlobSnippet.new(ref, grep.content, grep.startline, grep.filename)
        end
      end

      # Use the Rugged Walker API to build an array of commits.
      #
      # Usage.
      #   repo.log(
      #     ref: 'master',
      #     path: 'app/models',
      #     limit: 10,
      #     offset: 5,
      #   )
      #
      def log(options)
        default_options = {
          limit: 10,
          offset: 0,
          path: nil,
          ref: root_ref,
          follow: false
        }

        options = default_options.merge(options)
        actual_ref = options[:ref] || root_ref

        begin
          ref_sha = rugged.lookup(actual_ref).oid
        rescue Rugged::InvalidError, Rugged::OdbError
          # Maybe the ref isn't an SHA; try treating it as a tag or branch name
          ref_sha = get_sha_from_ref(actual_ref)
        end

        build_log(ref_sha, options)
      rescue Rugged::OdbError
        # Return an empty array if the ref wasn't found
        Array.new
      end

      # Delegate commits_between to Grit method
      #
      def commits_between(from, to)
        grit.commits_between(from, to)
      end

      def merge_base_commit(from, to)
        grit.git.native(:merge_base, {}, [to, from]).strip
      end

      def diff(from, to, *paths)
        grit.diff(from, to, *paths)
      end

      # Returns commits collection
      #
      # Ex.
      #   repo.find_commits(
      #     ref: 'master',
      #     max_count: 10,
      #     skip: 5,
      #     order: :date
      #   )
      #
      #   +options+ is a Hash of optional arguments to git
      #     :ref is the ref from which to begin (SHA1 or name)
      #     :contains is the commit contained by the refs from which to begin (SHA1 or name)
      #     :max_count is the maximum number of commits to fetch
      #     :skip is the number of commits to skip
      #     :order is the commits order and allowed value is :date(default) or :topo
      #
      def find_commits(options = {})
        actual_options = options.dup

        allowed_options = [:ref, :max_count, :skip, :contains, :order]

        actual_options.keep_if do |key, value|
          allowed_options.include?(key)
        end

        default_options = {pretty: 'raw', order: :date}

        actual_options = default_options.merge(actual_options)

        order = actual_options.delete(:order)

        case order
        when :date
          actual_options[:date_order] = true
        when :topo
          actual_options[:topo_order] = true
        end

        ref = actual_options.delete(:ref)

        containing_commit = actual_options.delete(:contains)

        args = []

        if ref
          args.push(ref)
        elsif containing_commit
          args.push(*branch_names_contains(containing_commit))
        else
          actual_options[:all] = true
        end

        output = grit.git.native(:rev_list, actual_options, *args)

        Grit::Commit.list_from_string(grit, output).map do |commit|
          Gitlab::Git::Commit.decorate(commit)
        end
      rescue Grit::GitRuby::Repository::NoSuchShaFound
        []
      end

      # Returns branch names collection that contains the special commit(SHA1 or name)
      #
      # Ex.
      #   repo.branch_names_contains('master')
      #
      def branch_names_contains(commit)
        output = grit.git.native(:branch, {contains: true}, commit)

        # Fix encoding issue
        output = EncodingHelper::encode!(output)

        # The output is expected as follow
        #   fix-aaa
        #   fix-bbb
        # * master
        output.scan(/[^* \n]+/)
      end

      # Get refs hash which key is SHA1
      # and value is ref object(Grit::Head or Grit::Remote or Grit::Tag)
      def refs_hash
        # Initialize only when first call
        if @refs_hash.nil?
          @refs_hash = Hash.new { |h, k| h[k] = [] }

          grit.refs.each do |r|
            @refs_hash[r.commit.id] << r
          end
        end
        @refs_hash
      end

      # Lookup for rugged object by oid
      def lookup(oid)
        rugged.lookup(oid)
      end

      # Return hash with submodules info for this repository
      #
      # Ex.
      #   {
      #     "rack"  => {
      #       "id" => "c67be4624545b4263184c4a0e8f887efd0a66320",
      #       "path" => "rack",
      #       "url" => "git://github.com/chneukirchen/rack.git"
      #     },
      #     "encoding" => {
      #       "id" => ....
      #     }
      #   }
      #
      def submodules(ref)
        Grit::Submodule.config(grit, ref)
      end

      # Return total commits count accessible from passed ref
      def commit_count(ref)
        walker = Rugged::Walker.new(rugged)
        walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_REVERSE)
        walker.push(ref)
        walker.count
      end

      private

      # Return the commit hash of a named ref.  Raises a Rugged::OdbError if
      # the ref_name argument isn't found in the repo.
      def get_sha_from_ref(ref_name)
        regex = Regexp.escape(ref_name)
        ref_obj = rugged.references.detect { |i| i.name.match(/#{regex}$/) }
        if ref_obj
          if ref_obj.target.is_a? Rugged::Tag::Annotation
            ref_obj.target.target.oid
          else
            ref_obj.target_id
          end
        else
          # No ref_obj means we couldn't find the ref in the repo
          raise Rugged::OdbError
        end
      end

      # Return an array of log commits, given an SHA hash and a hash of
      # options.
      def build_log(sha, options)
        # Instantiate a Walker and add the SHA hash
        walker = Rugged::Walker.new(rugged)
        walker.push(sha)

        commits = Array.new
        skipped = 0

        walker.each do |c|
          break if commits.length >= options[:limit]
          should_push = false
          sub_array = []
          if options[:path]
            if c.parents.length == 0
              # If there is no parent, then search the whole tree for the :path
              # argument
              c.tree.walk(:postorder) do |_, tree_blob|
                if tree_blob[:name].match(/^#{options[:path]}/)
                  should_push = true
                  break
                end
              end
            else
              # Check the commit's deltas to see if it touches the :path argument
              diff = c.parents[0].diff(c)
              diff.find_similar! if options[:follow]
              diff.each_delta do |d|
                should_push = false
                if d.new_file[:path].match(/^#{options[:path]}/) ||
                  d.old_file[:path].match(/^#{options[:path]}/)

                  should_push = true

                  if options[:follow] &&
                    d.new_file[:path] == options[:path] &&
                    d.old_file[:path] != d.new_file[:path]

                    # If the 'follow' option is true and the file was renamed,
                    # then walk back from the parent with the old path name.
                    sub_options = options.merge({
                      limit: options[:limit] - commits.length - 1,
                      offset: options[:offset] - skipped,
                      path: d.old_file[:path]
                    })
                    commits += build_log(c.parents[0].oid, sub_options)

                    walker.hide(c.parents[0].oid)
                  end

                  break
                end
              end
            end
          else
            # No :path option given
            should_push = true
          end

          if should_push
            skipped += 1
            commits.push(c) if skipped > options[:offset]
          end
        end

        commits
      end
    end
  end
end
