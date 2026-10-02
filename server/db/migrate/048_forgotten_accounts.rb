# frozen_string_literal: true

# The right to be forgotten: an account forgotten at the operator's console
# (bin/pemk_admin.rb forget) keeps its row - other players' Pokemon, trades and the audit
# name its id - with no personal data left, and says when. Additive: one nullable column.
Sequel.migration do
  change do
    alter_table(:accounts) do
      add_column :forgotten_at, DateTime
    end
  end
end
