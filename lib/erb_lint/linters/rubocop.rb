# frozen_string_literal: true

require 'better_html'
require 'rubocop'
require 'tempfile'

module ERBLint
  module Linters
    # Run selected rubocop cops on Ruby code
    class Rubocop < Linter
      include LinterRegistry

      class ConfigSchema < LinterConfig
        property :only, accepts: array_of?(String)
        property :rubocop_config, accepts: Hash
      end

      self.config_schema = ConfigSchema

      PREFIX_EXPR = /\A[[:blank:]]*/
      # copied from Rails: action_view/template/handlers/erb/erubi.rb
      BLOCK_EXPR = /\s*((\s+|\))do|\{)(\s*\|[^|]*\|)?\s*\Z/

      def initialize(file_loader, config)
        super
        @only_cops = @config.only
        custom_config = config_from_hash(@config.rubocop_config)
        @rubocop_config = RuboCop::ConfigLoader.merge_with_default(custom_config, '')
      end

      def offenses(processed_source)
        offenses = []
        processed_source.ast.descendants(:erb).each do |erb_node|
          offenses.push(*inspect_content(processed_source, erb_node))
        end
        offenses
      end

      def autocorrect(_processed_source, offense)
        return unless offense.new_content
        lambda do |corrector|
          corrector.replace(offense.replacement_range, offense.new_content)
        end
      end

      private

      class OffenseWithReplacement < Offense
        attr_reader :replacement_range, :new_content
        def initialize(linter, source_range, message, replacement_range:, new_content:)
          super(linter, source_range, message)
          @replacement_range = replacement_range
          @new_content = new_content
        end
      end

      def inspect_content(processed_source, erb_node)
        _, _, code_node, = *erb_node

        original_source = code_node.loc.source
        prefix = original_source.match(PREFIX_EXPR)&.to_a&.first
        suffix = original_source.match(BLOCK_EXPR)&.to_a&.first
        trimmed_source = original_source.sub(PREFIX_EXPR, '').sub(BLOCK_EXPR, '')
        aligned_source = "#{' ' * erb_node.loc.column}#{trimmed_source}"

        source = rubocop_processed_source(aligned_source)
        return unless source.valid_syntax?
        options = {
          extra_details: true,
          display_cop_names: true,
          auto_correct: true,
          stdin: "",
        }
        team = build_team(options)

        [].tap do |offenses|
          rubocop_offenses = team.inspect_file(source).reject(&:disabled?)

          rubocop_offenses&.each do |rubocop_offense|
            offset = code_node.loc.start - erb_node.loc.column + (prefix&.size || 0)
            offense_range = processed_source.to_source_range(
              offset + rubocop_offense.location.begin_pos,
              offset + rubocop_offense.location.end_pos - 1,
            )
            replacement_range = processed_source.to_source_range(
              code_node.loc.start,
              code_node.loc.stop,
            )
            new_content = if team.updated_source_file?
              "#{prefix}#{options[:stdin][erb_node.loc.column..-1]}#{suffix}"
            end
            offenses <<
              OffenseWithReplacement.new(
                self,
                offense_range,
                rubocop_offense.message.strip,
                replacement_range: replacement_range,
                new_content: new_content,
              )
          end
        end
      end

      def tempfile_from(filename, content)
        Tempfile.create(File.basename(filename), Dir.pwd) do |tempfile|
          tempfile.write(content)
          tempfile.rewind

          yield(tempfile)
        end
      end

      def rubocop_processed_source(content)
        RuboCop::ProcessedSource.new(
          content,
          @rubocop_config.target_ruby_version,
          '(erb)'
        )
      end

      def cop_classes
        if @only_cops.present?
          selected_cops = RuboCop::Cop::Cop.all.select { |cop| cop.match?(@only_cops) }
          RuboCop::Cop::Registry.new(selected_cops)
        elsif @rubocop_config['Rails']['Enabled']
          RuboCop::Cop::Registry.new(RuboCop::Cop::Cop.all)
        else
          RuboCop::Cop::Cop.non_rails
        end
      end

      def build_team(options)
        RuboCop::Cop::Team.new(
          cop_classes,
          @rubocop_config,
          options
        )
      end

      def config_from_hash(hash)
        inherit_from = hash.delete('inherit_from')
        resolve_inheritance(hash, inherit_from)

        tempfile_from('.erblint-rubocop', hash.to_yaml) do |tempfile|
          RuboCop::ConfigLoader.load_file(tempfile.path)
        end
      end

      def resolve_inheritance(hash, inherit_from)
        base_configs(inherit_from)
          .reverse_each do |base_config|
          base_config.each do |k, v|
            hash[k] = hash.key?(k) ? RuboCop::ConfigLoader.merge(v, hash[k]) : v if v.is_a?(Hash)
          end
        end
      end

      def base_configs(inherit_from)
        regex = URI::DEFAULT_PARSER.make_regexp(%w(http https))
        configs = Array(inherit_from).compact.map do |base_name|
          if base_name =~ /\A#{regex}\z/
            RuboCop::ConfigLoader.load_file(RuboCop::RemoteConfig.new(base_name, Dir.pwd))
          else
            config_from_hash(@file_loader.yaml(base_name))
          end
        end

        configs.compact
      end
    end
  end
end
