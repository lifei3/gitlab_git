# Libraries
require 'ostruct'
require 'fileutils'
require 'linguist'
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/object/try'
require 'rugged' unless defined?(Rails::Railtie)
require "charlock_holmes"

# Gitlab::Git
require_relative "gitlab_git/popen"
require_relative 'gitlab_git/encoding_helper'
require_relative "gitlab_git/blame"
require_relative "gitlab_git/blob"
require_relative "gitlab_git/commit"
require_relative "gitlab_git/commit_stats"
require_relative "gitlab_git/compare"
require_relative "gitlab_git/diff"
require_relative "gitlab_git/repository"
require_relative "gitlab_git/tree"
require_relative "gitlab_git/blob_snippet"
require_relative "gitlab_git/ref"
require_relative "gitlab_git/branch"
require_relative "gitlab_git/tag"
