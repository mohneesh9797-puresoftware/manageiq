class Blueprint < ApplicationRecord
  has_many :service_templates
  private  :service_templates, :service_templates=

  virtual_has_one :bundle

  acts_as_miq_taggable

  # the top of the service_templates, a bundle that contains child items
  def bundle
    service_templates.find { |st| st.parent_services.blank? }
  end

  # The new blueprint is saved before returning
  def deep_copy(new_attributes = {})
    self.class.transaction do
      dup.tap do |blueprint|
        # TODO: there may be other attributes that need to be reset for the new template
        new_attributes.reverse_merge(:status => nil).each do |attr, value|
          blueprint.send("#{attr}=", value)
        end
        copy_service_template(blueprint, bundle, true)
        blueprint.save!
      end
    end
  end

  def create_bundle(options)
    options = options.with_indifferent_access
    self.class.transaction do
      new_bundle = ServiceTemplate.create(
        :name         => name,
        :description  => description,
        :blueprint    => self,
        :service_type => 'composite'
      )
      add_catalog_items(new_bundle, options[:service_templates]) if options.key?(:service_templates)
      new_bundle.service_template_catalog = options[:service_catalog]

      if options.key?(:service_dialog)
        new_dialog = options[:service_dialog].deep_copy(:label => random_dialog_name(name)).tap(&:save!)
      end
      add_entry_points(new_bundle, options[:entry_points], new_dialog)

      new_bundle.save!
      reload.bundle
    end
  end

  def update_bundle(options)
    return create_bundle(options) unless bundle

    self.class.transaction do
      the_bundle = bundle
      update_catalog_items(the_bundle, options[:service_templates]) if options.key?(:service_templates)
      the_bundle.service_template_catalog = options[:service_catalog] if options.key?(:service_catalog)
      update_entry_points(the_bundle, options[:entry_points]) if options.key?(:entry_points)
      update_entry_points_dialog(the_bundle, options[:service_dialog]) if options.key?(:service_dialog)
      the_bundle.save!
      reload.bundle
    end
  end

  def content
    result = bundle.as_json.dup
    result["service_templates"] = bundle.descendants.map(&:as_json)
    result["service_catalog"] = bundle.service_template_catalog.as_json
    provision_action = bundle.resource_actions.find_by(:action => "Provision")
    result["service_dialog"] = provision_action.dialog.as_json if provision_action
    result["automate_entrypoints"] = bundle.resource_actions.map(&:as_json)
    result
  end

  private

  # Copy a service template and link its blueprint;
  # It can be used to copy service_templates into a new blueprint
  # or copy the bundle from one blueprint to another
  # The resulting service template is saved before returning;
  # is_top is true only when copying the bundle of a blueprint
  def copy_service_template(blueprint, service_template, is_top = false, new_attributes = {})
    service_template.dup.tap do |new_template|
      duplicate_resource_actions(service_template, new_template, is_top)
      duplicate_service_resources(blueprint, service_template, new_template)
      update_copied_service_template(blueprint, new_template, new_attributes)
      duplicate_custom_buttons(service_template, new_template) if is_top
      duplicate_custom_button_sets(service_template, new_template) if is_top
    end
  end

  def duplicate_resource_actions(old_template, new_template, is_top)
    dialog_map = {}
    new_template.resource_actions = old_template.resource_actions.collect do |old_action|
      old_action.dup.tap do |new_action|
        old_dialog = old_action.dialog
        new_dialog = ensure_new_dialog(dialog_map, old_dialog) if old_dialog && is_top
        new_action.dialog = new_dialog # either a new dialog or nil
      end
    end
  end

  def ensure_new_dialog(dialog_map, old_dialog)
    new_dialog = dialog_map[old_dialog.id]
    unless new_dialog
      new_dialog = old_dialog.deep_copy(:label => random_dialog_name(old_dialog.name)).tap(&:save!)
      dialog_map[old_dialog.id] = new_dialog
    end
    new_dialog
  end

  def random_dialog_name(prefix)
    "#{prefix}_#{rand(36**8).to_s(36)}"
  end

  def duplicate_service_resources(blueprint, old_template, new_template)
    new_template.service_resources = old_template.service_resources.collect do |sr|
      sr.dup.tap do |new_sr|
        resource = sr.resource
        if resource.kind_of?(ServiceTemplate)
          new_sr.resource = copy_service_template(blueprint, resource)
        elsif !provider_resource?(resource)
          new_sr.resource = resource.dup.tap(&:save!)
        end
      end
    end
  end

  def provider_resource?(resource)
    resource.respond_to?(:ems_ref) || resource.kind_of?(ExtManagementSystem)
  end

  def update_copied_service_template(blueprint, new_template, new_attributes)
    new_template.blueprint = blueprint
    new_template.display = false

    new_attributes.each do |attr, value|
      new_template.send("#{attr}=", value)
    end

    new_template.save!
  end

  def add_catalog_items(new_bundle, catalog_items)
    catalog_items.each do |item|
      new_bundle.add_resource(copy_service_template(self, item, false))
    end
  end

  def update_catalog_items(the_bundle, catalog_items)
    existing_ids = the_bundle.service_templates.collect(&:id)
    catalog_items.each do |item|
      unless existing_ids.delete(item.id)
        # new item
        add_catalog_items(the_bundle, [item])
      end
    end

    # remove items
    ServiceTemplate.where(:id => existing_ids).each do |remaining_item|
      the_bundle.remove_resource(remaining_item)
      remaining_item.destroy!
    end
  end

  def add_entry_points(new_bundle, entry_points, dialog)
    entry_points ||= {
      'Provision'  => ServiceTemplate.default_provisioning_entry_point,
      'Retirement' => ServiceTemplate.default_retirement_entry_point
    }

    entry_points.each do |key, value|
      new_bundle.resource_actions.build(:action => key, :fqname => value, :dialog => dialog)
    end
  end

  def update_entry_points(the_bundle, entry_points)
    existing_actions = the_bundle.resource_actions
    entry_points.each do |key, value|
      action = existing_actions.find_by(:action => key)
      if action
        action.update_attribute(:fqname, value)
      else
        existing_actions.build(:action => key, :fqname => value, :dialog => existing_actions.first.dialog)
      end
    end
  end

  def update_entry_points_dialog(the_bundle, input_dialog)
    existing_actions = the_bundle.resource_actions
    return if existing_actions.blank?

    existing_dialog = bundle.dialogs.first
    return existing_dialog if input_dialog.try(:id) == existing_dialog.try(:id)

    new_dialog = input_dialog ? input_dialog.deep_copy(:label => random_dialog_name(name)).tap(&:save!) : nil
    existing_actions.update_all(:dialog_id => new_dialog.try(:id))
    existing_dialog.destroy if existing_dialog
  end

  def duplicate_custom_buttons(old_template, new_template)
    old_template.direct_custom_buttons.each do |old_button|
      old_button.copy(:applies_to => new_template)
    end
  end

  def duplicate_custom_button_sets(old_template, new_template)
    old_template.custom_button_sets.each do |old_button_set|
      old_button_set.deep_copy(:owner => new_template)
    end
  end
end
