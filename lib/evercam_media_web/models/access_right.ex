defmodule AccessRight do
  use EvercamMediaWeb, :model
  alias EvercamMedia.Repo
  import Ecto.Query

  @required_fields ~w(token_id right status)
  @optional_fields ~w(camera_id grantor_id snapshot_id account_id scope updated_at created_at)
  @camera_rights ["delete", "edit", "list", "snapshot", "share", "view", "grant~delete",
                  "grant~edit", "grant~list", "grant~snapshot", "grant~share", "grant~view"]
  @status %{active: 1, deleted: -1}

  schema "access_rights" do
    belongs_to :access_token, AccessToken, foreign_key: :token_id
    belongs_to :camera, Camera, foreign_key: :camera_id
    belongs_to :grantor, User, foreign_key: :grantor_id
    belongs_to :snapshot, Snapshot, foreign_key: :snapshot_id
    belongs_to :account, User, foreign_key: :account_id

    field :right, :string
    field :status, :integer
    field :scope, :string
    timestamps(inserted_at: :created_at, type: Ecto.DateTime, default: Ecto.DateTime.utc)
  end

  def allows?(requester, resource, right, scope) do
    token_id = AccessToken.active_token_id_for(requester.id)

    access_rights =
      AccessRight
      |> where([ar], ar.token_id == ^token_id)
      |> where(account_id: ^resource.id)
      |> where(status: 1)
      |> where(right: ^right)
      |> where(scope: ^scope)
      |> Repo.all

    case access_rights do
      nil -> false
      [] -> false
      _ -> true
    end
  end

  def camera_rights, do: @camera_rights

  def valid_right_name?(name) when name in [nil, ""], do: false
  def valid_right_name?(name) do
    Enum.member?(@camera_rights, name)
  end

  def grant(user, camera, rights) do
    token_id = AccessToken.active_token_id_for(user.id)
    saved_rights = recorded_rights(user, camera)
    rights
    |> Enum.reject(fn(right) -> Enum.member?(saved_rights, right) end)
    |> Enum.each(fn(right) ->
      unless Camera.is_owner?(user, camera) do
        right_params = %{token_id: token_id, camera_id: camera.id, right: right, status: @status.active}
        %AccessRight{}
        |> changeset(right_params)
        |> Repo.insert
      end
    end)
  end

  def recorded_rights(user, camera) do
    token_id = AccessToken.active_token_id_for(user.id)
    AccessRight
    |> where(token_id: ^token_id)
    |> where(camera_id: ^camera.id)
    |> where(status: ^@status.active)
    |> Repo.all
    |> Enum.map(fn(ar) -> ar.right end)
    |> Enum.uniq
  end

  def revoke(user, camera, rights) do
    token_id = AccessToken.active_token_id_for(user.id)
    if !Camera.is_owner?(user, camera) do
      AccessRight
      |> where(token_id: ^token_id)
      |> where(camera_id: ^camera.id)
      |> where(status: ^@status.active)
      |> where([r], r.right in ^rights)
      |> Repo.update_all(set: [status: @status.deleted])
    end
  end

  def required_fields do
    @required_fields |> Enum.map(fn(field) -> String.to_atom(field) end)
  end

  def changeset(model, params \\ :invalid) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required(required_fields())
  end
end
