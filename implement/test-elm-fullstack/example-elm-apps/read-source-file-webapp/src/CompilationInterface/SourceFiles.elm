module CompilationInterface.SourceFiles exposing (..)

{-| For documentation of the compilation interface, see <https://github.com/elm-fullstack/elm-fullstack/blob/main/guide/how-to-configure-and-deploy-an-elm-fullstack-app.md#compilationinterfacesourcefiles-elm-module>
-}


type FileTreeNode blobStructure
    = BlobNode blobStructure
    | TreeNode (List ( String, FileTreeNode blobStructure ))


file_tree____static_content : FileTreeNode { base64 : String }
file_tree____static_content =
    TreeNode []


file____readme_md : { utf8 : String }
file____readme_md =
    { utf8 = "The compiler replaces this value." }
