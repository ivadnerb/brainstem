require 'brainstem/search_unavailable_error'

module Brainstem
  class PresenterCollection

    # @!attribute default_max_per_page
    # @return [Integer] The maximum number of objects that can be requested in a single presented hash.
    attr_accessor :default_max_per_page

    # @!attribute default_per_page
    # @return [Integer] The default number of objects that will be returned in the presented hash.
    attr_accessor :default_per_page

    # @!visibility private
    def initialize
      @default_per_page = 20
      @default_max_per_page = 200
    end

    # The main presentation method, converting a model name and an optional scope into a hash structure, ready to be converted into JSON.
    # If searching, Brainstem filtering, only, pagination, and ordering are skipped and should be implemented with your search solution.
    # All request options are passed to the +search_block+ for your convenience.
    # @param [Class, String] name The class of the objects to be presented.
    # @param [Hash] options The options that will be applied as the objects are converted.
    # @option options [Hash] :params The +params+ hash included in a request for the presented object.
    # @option options [ActiveRecord::Base] :model The model that is being presented (if different from +name+).
    # @option options [String] :brainstem_key The top-level key the presented objects will be assigned to (if different from +name.tableize+)
    # @option options [Integer] :max_per_page The maximum number of items that can be requested by <code>params[:per_page]</code>.
    # @option options [Integer] :per_page The number of items that will be returned if <code>params[:per_page]</code> is not set.
    # @option options [Boolean] :apply_default_filters Determine if Presenter's filter defaults should be applied.  On by default.
    # @option options [Brainstem::Presenter] :primary_presenter The Presenter to use for filters and sorts. If unspecified, the +:model+ or +name+ will be used to find an appropriate Presenter.
    # @yield Must return a scope on the model +name+, which will then be presented.
    # @return [Hash] A hash of arrays of hashes. Top-level hash keys are pluralized model names, with values of arrays containing one hash per object that was found by the given given options.
    def presenting(name, options = {}, &block)
      options[:params] = HashWithIndifferentAccess.new(options[:params] || {})
      check_for_old_options(options)
      set_default_filters_option!(options)
      presented_class = (options[:model] || name)
      presented_class = presented_class.classify.constantize if presented_class.is_a?(String)
      scope = presented_class.instance_eval(&block)
      count = 0

      # grab the presenter that knows about filters and sorting etc.
      options[:primary_presenter] ||= for!(presented_class)

      # table name will be used to query the database for the filtered data
      options[:table_name] = presented_class.table_name

      # key these models will use in the struct that is output
      options[:brainstem_key] = (options[:brainstem_key] || name.to_s.tableize).to_sym

      # filter the incoming :includes list by those available from this Presenter in the current context
      selected_associations = filter_includes(options)

      if searching? options
        # Search
        sort_name, direction = calculate_sort_name_and_direction options
        scope, count, ordered_search_ids = run_search(scope, selected_associations.map(&:name).map(&:to_s), sort_name, direction, options)
      else
        # Filter
        scope = run_filters scope, options

        if options[:params][:only].present?
          # Handle Only
          scope, count = handle_only(scope, options[:params][:only])
        else
          # Paginate
          scope, count = paginate scope, options
        end

        count = count.keys.length if count.is_a?(Hash)

        # Ordering
        scope = handle_ordering scope, options
      end

      # Load models!
      primary_models = scope.to_a

      # Determine if an exception should be raised on an empty result set.
      if options[:raise_on_empty] && primary_models.empty?
        raise options[:empty_error_class] || ActiveRecord::RecordNotFound
      end

      primary_models = order_for_search(primary_models, ordered_search_ids) if searching?(options)

      # Preload associations
      # Preloader.new(primary_models, options[:primary_presenter], selected_associations).preload!

      # Load request associations
      associated_models = gather_associations(primary_models, selected_associations)

      struct = { :count => count, options[:brainstem_key] => [], :results => [] }

      associated_models.each do |brainstem_key, models|
        models.flatten!
        models.uniq!

        if models.length > 0
          # TODO: handle polymorphism here
          presenter = for!(models.first.class)
          struct[brainstem_key] = presenter.group_present(models)
        else
          struct[brainstem_key] = []
        end
      end

      if primary_models.length > 0
        # TODO: handle polymorphism here
        presented_primary_models = options[:primary_presenter].group_present(primary_models, selected_associations.map(&:name))
        struct[options[:brainstem_key]] += presented_primary_models
        struct[:results] = presented_primary_models.map { |model| { :key => options[:brainstem_key].to_s, :id => model[:id] } }
      end

      rewrite_keys_as_objects!(struct)

      struct
    end

    # @return [Hash] The presenters this collection knows about, keyed on the names of the classes that can be presented.
    def presenters
      @presenters ||= {}
    end

    # @param [String, Class] presenter_class The presenter class that knows how to present all of the classes given in +klasses+.
    # @param [*Class] klasses One or more classes that can be presented by +presenter_class+.
    def add_presenter_class(presenter_class, *klasses)
      klasses.each do |klass|
        presenters[klass.to_s] = presenter_class.new
      end
    end

    # @return [Brainstem::Presenter, nil] The presenter that knows how to present the class +klass+, or +nil+ if there isn't one.
    def for(klass)
      presenters[klass.to_s]
    end

    # @return [Brainstem::Presenter] The presenter that knows how to present the class +klass+.
    # @raise [ArgumentError] if there is no known presenter for +klass+.
    def for!(klass)
      self.for(klass) || raise(ArgumentError, "Unable to find a presenter for class #{klass}")
    end

    private

    def paginate(scope, options)
      if options[:params][:limit].present? && options[:params][:offset].present?
        limit = calculate_limit(options)
        offset = calculate_offset(options)
      else
        limit = calculate_per_page(options)
        offset = limit * (calculate_page(options) - 1)
      end

      [scope.limit(limit).offset(offset).uniq, scope.select("distinct #{scope.connection.quote_table_name options[:table_name]}.id").count] # as of Rails 3.2.5, uniq.count generates the wrong SQL.
    end

    def calculate_per_page(options)
      per_page = [(options[:params][:per_page] || options[:per_page] || default_per_page).to_i, (options[:max_per_page] || default_max_per_page).to_i].min
      per_page = default_per_page if per_page < 1
      per_page
    end

    def calculate_page(options)
      [(options[:params][:page] || 1).to_i, 1].max
    end

    def calculate_limit(options)
      [[options[:params][:limit].to_i, 1].max, default_max_per_page].min
    end

    def calculate_offset(options)
      [options[:params][:offset].to_i, 0].max
    end

    def filter_includes(options)
      allowed_associations = options[:primary_presenter].allowed_associations(options[:params][:only].present?)

      [].tap do |selected_associations|
        (options[:params][:include] || '').split(',').each do |k|
          # TODO: make sure a spec breaks if this line is changed (it should)
          if association = allowed_associations[k]
            selected_associations << association
          end
        end
      end
    end

    def handle_only(scope, only)
      ids = (only || "").split(",").select {|id| id =~ /\A\d+\z/}.uniq
      [scope.where(:id => ids), scope.where(:id => ids).count]
    end

    def run_filters(scope, options)
      extract_filters(options).each do |filter_name, arg|
        next if arg.nil?
        filter_lambda = options[:primary_presenter].filters[filter_name][1]

        if filter_lambda
          scope = filter_lambda.call(scope, arg)
        else
          scope = scope.send(filter_name, arg)
        end
      end

      scope
    end

    def extract_filters(options)
      filters_hash = {}
      run_defaults = options.fetch(:apply_default_filters) { true }

      (options[:primary_presenter].filters || {}).each do |filter_name, filter|
        requested = options[:params][filter_name]
        requested = requested.is_a?(Array) ? requested : (requested.present? ? requested.to_s : nil)
        requested = requested == "true" ? true : (requested == "false" ? false : requested)

        filter_options = filter[0]
        args = run_defaults && requested.nil? ? filter_options[:default] : requested
        filters_hash[filter_name] = args unless args.nil?
      end

      filters_hash
    end

    # Runs the current search_block and returns an array of [scope of the resulting ids, result count, result ids]
    # If the search_block returns a falsy value a SearchUnavailableError is raised.
    # Your search block should return a list of ids and the count of ids found, or false if search is unavailable.
    def run_search(scope, includes, sort_name, direction, options)
      return scope unless searching? options

      search_options = HashWithIndifferentAccess.new(
        :include => includes,
        :order => { :sort_order => sort_name, :direction => direction },
      )

      if options[:params][:limit].present? && options[:params][:offset].present?
        search_options[:limit] = calculate_limit(options)
        search_options[:offset] = calculate_offset(options)
      else
        search_options[:per_page] = calculate_per_page(options)
        search_options[:page] = calculate_page(options)
      end

      search_options.reverse_merge!(extract_filters(options))

      result_ids, count = options[:primary_presenter].search_block.call(options[:params][:search], search_options)
      if result_ids
        [scope.where(:id => result_ids ), count, result_ids]
      else
        raise(SearchUnavailableError, 'Search is currently unavailable')
      end
    end

    def searching?(options)
      options[:params][:search] && options[:primary_presenter].search_block.present?
    end

    def order_for_search(records, ordered_search_ids)
      ids_to_position = {}
      ordered_records = []

      ordered_search_ids.each_with_index do |id, index|
        ids_to_position[id] = index
      end

      records.each do |record|
        ordered_records[ids_to_position[record.id]] = record
      end

      ordered_records
    end

    def handle_ordering(scope, options)
      order, direction = calculate_order_and_direction(options)

      case order
        when Proc
          order.call(scope, direction)
        when nil
          scope
        else
          scope.order(order.to_s + " " + direction)
      end
    end

    def calculate_order_and_direction(options)
      sort_name, direction = calculate_sort_name_and_direction(options)
      sort_orders = (options[:primary_presenter].sort_orders || {})
      order = sort_orders[sort_name]

      [order, direction]
    end

    def calculate_sort_name_and_direction(options)
      default_column, default_direction = (options[:primary_presenter].default_sort_order || "updated_at:desc").split(":")
      sort_name, direction = (options[:params][:order] || "").split(":")
      sort_orders = options[:primary_presenter].sort_orders || {}
      unless sort_name.present? && sort_orders[sort_name]
        sort_name = default_column
        direction = default_direction
      end

      [sort_name, direction == 'desc' ? 'desc' : 'asc']
    end

    def gather_associations(models, selected_associations)
      selected_associations.each.with_object({}) do |association, record_hash|
        association.load_records_into_hash!(models, record_hash)
      end
    end

    def rewrite_keys_as_objects!(struct)
      (struct.keys - [:count, :results]).each do |key|
        struct[key] = struct[key].inject({}) {|memo, obj| memo[obj[:id] || obj["id"] || "unknown_id"] = obj; memo }
      end
    end

    def set_default_filters_option!(options)
      return unless options[:params].has_key?(:apply_default_filters)

      options[:apply_default_filters] = [true, "true", "TRUE", 1, "1"].include? options[:params].delete(:apply_default_filters)
    end

    def check_for_old_options(options)
      raise "The 'as' parameter has been renamed to 'brainstem_key'" if options[:as].present?
    end

    # Class Methods

    # In Rails 4.2, ActiveRecord::Base#reflections started being keyed by strings instead of symbols.
    def self.reflections(klass)
      klass.reflections.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
    end

    def self.preload(models, association_names)
      if Gem.loaded_specs['activerecord'].version >= Gem::Version.create('4.1')
        ActiveRecord::Associations::Preloader.new.preload(models, association_names)
      else
        ActiveRecord::Associations::Preloader.new(models, association_names).run
      end
    end
  end
end
