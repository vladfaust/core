require "db"
require "./query_logger"

# `Repository` is a gateway between `Model`s and Database.
#
# It allows to `#query`, `#insert`, `#update` and `#delete` models.
#
# See `Query` for a handy queries builder.
#
# ```
# logger = Core::QueryLogger.new(STDOUT)
# repo = Core::Repository(User).new(db, logger)
#
# user = User.new(name: "Foo")
# repo.insert(user) # TODO: [RFC] Return last inserted ID
# # INSERT INTO users (name, created_at) VALUES ($1, $2) RETURNING id
# # 1.773ms
#
# query = Query(User).last
# user = repo.query(query).first
# # SELECT * FROM users ORDER BY id DESC LIMIT 1
# # 275μs
#
# user.name = "Bar"
# repo.update(user) # TODO: [RFC] Return a number of affected rows
# # UPDATE users SET name = $1 WHERE (id = $2) RETURNING id
# # 1.578ms
#
# repo.delete(user)
# # DELETE FROM users WHERE id = $1
# # 1.628ms
# ```
class Core::Repository(ModelType)
  # :nodoc:
  property db
  # :nodoc:
  property query_logger

  # Initialize a new `Repository` istance linked to *db*,
  # which is data storage, and *query_logger*,
  # which logs Database queries.
  #
  # NOTE: *db* and *query_logger* can be changed in the runtime with according `#db=` and `#query_logger=` methods.
  def initialize(@db : DB::Database, @query_logger : QueryLogger)
  end

  # Issue a query to the `#db`. Returns an array of `Model` instances.
  #
  # TODO: Handle errors (PQ::PQError)
  def query(query : String, *params) : Array(ModelType)
    query = prepare_query(query)
    params = prepare_params(*params) if params.any?

    query_logger.wrap(query) do
      db.query_all(query, *params) do |rs|
        rs.read(ModelType)
      end
    end
  end

  # ditto
  def query(query : Query)
    query(query.to_s, query.params)
  end

  private SQL_INSERT = <<-SQL
  INSERT INTO %{table_name} (%{keys}) VALUES (%{values}) RETURNING %{returning}
  SQL

  # Insert *instance* into Database.
  # Returns last inserted ID (doesn't work for PostgreSQL driver yet: https://github.com/will/crystal-pg/issues/112).
  #
  # NOTE: Does not check if `Model::Validation#valid?`.
  #
  # TODO: Handle errors.
  # TODO: Multiple inserts.
  # TODO: [RFC] Call `#query` and return `Model` instance instead (see https://github.com/will/crystal-pg/issues/101).
  def insert(instance : ModelType) : Int64
    fields = instance.db_fields.dup.tap do |f|
      f.each do |k, _|
        f[k] = now if ModelType.created_at_fields.includes?(k) && f[k].nil?
        f.delete(k) if k == ModelType.primary_key
      end
    end

    query = SQL_INSERT % {
      table_name: ModelType.table_name,
      keys:       fields.keys.join(", "),
      values:     (1..fields.size).map { "?" }.join(", "),
      returning:  ModelType.primary_key,
    }

    query = prepare_query(query)
    params = prepare_params(fields.values)

    query_logger.wrap(query) do
      db.exec(query, *params).last_insert_id
    end
  end

  private SQL_UPDATE = <<-SQL
  UPDATE %{table_name} SET %{set_fields} WHERE %{primary_key} = ? RETURNING %{returning}
  SQL

  # Update *instance*.
  # Only fields appearing in `Model#changes` are affected.
  # Returns affected rows count (doesn't work for PostgreSQL driver yet: [https://github.comwill/crystal-pg/issues/112](https://github.com/will/crystal-pg/issues/112)).
  #
  # NOTE: Does not check if `Model::Validation#valid?`.
  #
  # TODO: Handle errors.
  # TODO: Multiple updates.
  # TODO: [RFC] Call `#query` and return `Model` instance instead (see https://github.com/will/crystal-pg/issues/101).
  def update(instance : ModelType)
    fields = instance.db_fields.select do |k, _|
      instance.changes.keys.includes?(k)
    end.tap do |f|
      f.each do |k, _|
        f[k] = now if ModelType.updated_at_fields.includes?(k)
      end
    end

    return unless fields.any?

    query = SQL_UPDATE % {
      table_name:  ModelType.table_name,
      set_fields:  fields.keys.map { |k| k.to_s + " = ?" }.join(", "),
      primary_key: ModelType.primary_key, # TODO: Handle empty primary key
      returning:   ModelType.primary_key,
    }

    query = prepare_query(query)
    params = prepare_params(fields.values.push(instance.primary_key_value))

    query_logger.wrap(query) do
      db.exec(query, *params).rows_affected
    end
  end

  private SQL_DELETE = <<-SQL
  DELETE FROM %{table_name} WHERE %{primary_key} = ?
  SQL

  # Delete *instance* from Database.
  # Returns affected rows count (doesn't work for PostgreSQL driver yet: https://github.com/will/crystal-pg/issues/112).
  #
  # TODO: Handle errors.
  # TODO: Multiple deletes.
  def delete(instance : ModelType)
    query = SQL_DELETE % {
      table_name:  ModelType.table_name,
      primary_key: ModelType.primary_key,
    }

    query = prepare_query(query)
    params = prepare_params([instance.primary_key_value])

    query_logger.wrap(query) do
      db.exec(query, *params).rows_affected
    end
  end

  # Prepare *query* for execution.
  private def prepare_query(query : String) : String
    if db.driver.is_a?(PG::Driver)
      counter = 0
      query = query.as(String).gsub("?") { "$" + (counter += 1).to_s }
    end

    query
  end

  private def prepare_params(*params)
    params.map do |a|
      a.map do |p|
        if p.is_a?(Enum)
          p.value
        else
          p
        end
      end
    end
  end

  private def now
    "NOW()"
  end
end