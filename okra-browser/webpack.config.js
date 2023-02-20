import path from "node:path";

export default {
  mode: "development",
  stats: "minimal",
  devtool: "inline-source-map",
  entry: path.resolve("demo", "src", "index.tsx"),
  output: {
    path: path.resolve("demo", "dist"),
    filename: "index.js",
    module: true,
  },
  module: {
    rules: [
      {
        test: /\.tsx?$/,
        loader: "ts-loader",
        options: { configFile: "demo/tsconfig.json" },
        exclude: /node_modules/,
      },
    ],
  },
  resolve: {
    extensions: [".js", ".ts", ".tsx"],
    extensionAlias: {
      ".js": [".js", ".ts", ".tsx"],
    },
  },
  experiments: {
    topLevelAwait: true,
    outputModule: true,
  },
  devServer: {
    static: [path.resolve("demo", "public")],
    hot: false,
  },
};
