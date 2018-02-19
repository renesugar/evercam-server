defmodule CameraShare do
  use EvercamMediaWeb, :model
  alias EvercamMedia.Repo
  import Ecto.Query

  @required_fields ~w(camera_id user_id kind)
  @optional_fields ~w(sharer_id message updated_at created_at)

  schema "camera_shares" do
    belongs_to :camera, Camera
    belongs_to :user, User
    belongs_to :sharer, User, foreign_key: :sharer_id

    field :kind, :string
    field :message, :string
    timestamps(inserted_at: :created_at, type: Ecto.DateTime, default: Ecto.DateTime.utc)
  end

  def rights_list("full"), do: ["snapshot", "view", "edit", "list"]
  def rights_list("minimal+share"), do: ["snapshot", "share", "list"]
  def rights_list(_), do: ["snapshot", "list"]

  def create_share(camera, sharee, sharer, rights, message, kind \\ "private") do
    share_params =
      %{
        camera_id: camera.id,
        user_id: sharee.id,
        sharer_id: sharer.id,
        kind: kind,
        message: message,
        rights: rights,
        owner: camera.owner.id
      }
    share_changeset = changeset(%CameraShare{}, share_params)
    case Repo.insert(share_changeset) do
      {:ok, share} ->
        rights_list = to_rights_list(rights)
        AccessRight.grant(sharee, camera, rights_list)
        camera_share =
          share
          |> Repo.preload(:user)
          |> Repo.preload(:sharer)
          |> Repo.preload(:camera)
          |> Repo.preload([camera: :access_rights])
          |> Repo.preload([camera: [access_rights: :access_token]])
        {:ok, camera_share}
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_share(sharee, camera, rights) do
    rights_list = to_rights_list(rights)
    revoke_rights =
      AccessRight.camera_rights
      |> Enum.reject(fn(right) -> Enum.member?(rights_list, right) end)
    AccessRight.revoke(sharee, camera, revoke_rights)
    AccessRight.grant(sharee, camera, rights_list)
  end

  def to_rights_list(rights) do
    rights
    |> String.downcase
    |> String.split(",", trim: true)
    |> Enum.map(fn(right) -> String.trim(right) end)
    |> Enum.filter(fn(right) -> AccessRight.valid_right_name?(right) end)
  end

  def delete_share(user, camera) do
    rights = AccessRight.camera_rights
    AccessRight.revoke(user, camera, rights)
    CameraShare
    |> where(camera_id: ^camera.id)
    |> where(user_id: ^user.id)
    |> Repo.delete_all
  end

  def delete_by_camera_id(camera_id) do
    CameraShare
    |> where(camera_id: ^camera_id)
    |> Repo.delete_all
  end

  def camera_shares(camera) do
    CameraShare
    |> where(camera_id: ^camera.id)
    |> preload(:user)
    |> preload(:sharer)
    |> preload(:camera)
    |> preload([camera: :access_rights])
    |> preload([camera: [access_rights: :access_token]])
    |> Repo.all
  end

  def user_camera_share(camera, user) do
    CameraShare
    |> where(user_id: ^user.id)
    |> or_where(sharer_id: ^user.id)
    |> where(camera_id: ^camera.id)
    |> preload(:user)
    |> preload(:sharer)
    |> preload(:camera)
    |> preload([camera: :access_rights])
    |> preload([camera: [access_rights: :access_token]])
    |> Repo.all
  end

  def shared_users(user_id, camera_id) when camera_id in [nil, ""] do
    CameraShare
    |> join(:inner, [u], cam in Camera)
    |> where([cs, cam], cam.id == cs.camera_id)
    |> where([cs, cam], cam.owner_id == ^user_id)
    |> join(:inner, [u], user in User)
    |> where([cs, cam, user], user.id == cs.user_id)
    |> preload(:user)
    |> Repo.all
  end
  def shared_users(user_id, camera_id) do
    remove_already_shared =
      camera_id
      |> Camera.get
      |> get_camera_all_shared_user

    CameraShare
    |> join(:inner, [u], cam in Camera)
    |> where([cs, cam], cam.id == cs.camera_id)
    |> where([cs, cam], cam.owner_id == ^user_id)
    |> join(:inner, [u], user in User)
    |> where([cs, cam, user], user.id == cs.user_id)
    |> where([cs, cam, user], not user.id in ^remove_already_shared)
    |> preload(:user)
    |> Repo.all
  end

  def get_camera_all_shared_user(nil), do: []
  def get_camera_all_shared_user(camera) do
    CameraShare
    |> where(camera_id: ^camera.id)
    |> preload(:user)
    |> Repo.all
    |> Enum.filter(fn(share) -> share.user != nil end)
    |> Enum.map(fn(share) -> share.user.id end)
  end

  def by_user_and_camera(camera_id, user_id) do
    CameraShare
    |> where(camera_id: ^camera_id)
    |> where(user_id: ^user_id)
    |> preload(:user)
    |> preload(:sharer)
    |> preload(:camera)
    |> preload([camera: :access_rights])
    |> preload([camera: [access_rights: :access_token]])
    |> Repo.one
  end

  def get_rights("private", user, camera) do
    ["snapshot", "list", "share", "view", "edit", "delete"]
    |> Enum.filter(fn(right) -> Permission.Camera.can_access?(right, user, camera) end)
    |> Enum.join(",")
  end

  def get_rights("public", _user, _camera) do
    ["snapshot", "list"]
    |> Enum.join(",")
  end

  def validate_rights(changeset) do
    rights = get_field(changeset, :rights)
    validate_rights(changeset, rights)
  end

  def validate_rights(changeset, rights) do
    with true <- rights != nil && rights != "",
         access_rights = rights |> CameraShare.to_rights_list |> Enum.join(","),
         true <- String.downcase(rights) == access_rights
    do
      changeset
    else
      false -> add_error(changeset, :rights, "Invalid rights specified in request.")
    end
  end

  def html_sanitize_message(changeset) do
    case get_field(changeset, :message) do
      nil -> changeset
      _message -> changeset |> update_change(:message, &HtmlSanitizeEx.strip_tags/1)
    end
  end

  defp can_share(changeset, owner) do
    sharee = get_field(changeset, :user_id)
    sharer = get_field(changeset, :sharer_id)

    cond do
      sharee == owner && sharer == owner ->
        add_error(changeset, :share, "You can't share with yourself.")
      sharee == owner && sharer != owner ->
        add_error(changeset, :share, "Sharee is the camera owner - you cannot remove their rights.")
      true -> changeset
    end
  end

  def delete_by_user(user_id) do
    CameraShare
    |> where(user_id: ^user_id)
    |> Repo.delete_all
  end

  def required_fields do
    @required_fields |> Enum.map(fn(field) -> String.to_atom(field) end)
  end

  def changeset(model, params \\ :invalid) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required(required_fields())
    |> unique_constraint(:share, [name: "camera_shares_camera_id_user_id_index", message: "The camera has already been shared with this user."])
    |> validate_rights(params[:rights])
    |> can_share(params[:owner])
    |> html_sanitize_message
  end
end
