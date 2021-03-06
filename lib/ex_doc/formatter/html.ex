defmodule ExDoc.Formatter.HTML do
  @moduledoc """
  Generate HTML documentation for Elixir projects
  """

  alias ExDoc.Formatter.HTML.Templates
  alias ExDoc.Formatter.HTML.Autolink

  @main "api-reference"

  @doc """
  Generate HTML documentation for the given modules
  """
  @spec run(list, ExDoc.Config.t) :: String.t
  def run(module_nodes, config) when is_map(config) do
    config = normalize_config(config)
    output = Path.expand(config.output)
    build = Path.join(output, ".build")

    output_setup(build, output)

    assets = assets() |> assets_path() |> generate_assets(output)

    all = Autolink.all(module_nodes)
    modules    = filter_list(:modules, all)
    exceptions = filter_list(:exceptions, all)
    protocols  = filter_list(:protocols, all)

    config =
      if config.logo do
        process_logo_metadata(config, "#{config.output}/assets")
      else
        config
      end

    generate_api_reference(modules, exceptions, protocols, output, config)
    extras = generate_extras(output, module_nodes, modules, exceptions, protocols, config)

    generated_files =
      generate_index(output, config) ++
      generate_not_found(modules, exceptions, protocols, output, config) ++
      generate_sidebar_items(modules, exceptions, protocols, extras, output) ++
      generate_list(modules, modules, exceptions, protocols, output, config) ++
      generate_list(exceptions, modules, exceptions, protocols, output, config) ++
      generate_list(protocols, modules, exceptions, protocols, output, config)

    generate_build(extras, generated_files ++ assets, build)

    Path.join(config.output, "index.html")
  end

  defp normalize_config(%{main: "index"}) do
    raise ArgumentError, message: ~S("main" cannot be set to "index", otherwise it will recursively link to itself)
  end
  defp normalize_config(%{main: main} = config) do
    %{config | main: main || @main}
  end

  defp output_setup(build, output) do
    if File.exists? build do
      Enum.each(File.stream!(build), fn(line) ->
        line = String.replace(line, "\n", "")
        File.rm(Path.join(output, line))
      end)
      File.rm(build)
    else
      File.rm_rf! output
      File.mkdir_p! output
    end
  end

  defp generate_build(extras, generated_files, output) do
    extras = for {file, _, _} <- extras, do: "#{file}.html"
    build_files = Enum.map(Enum.uniq(generated_files ++ extras), &[&1, "\n"])

    File.write!(output, build_files)
  end

  defp generate_index(output, config) do
    index_file = "index.html"
    main_file = "#{config.main}.html"
    generate_redirect(output, index_file, config, main_file)
    [index_file, main_file]
  end

  defp generate_api_reference(modules, exceptions, protocols, output, config) do
    file_name = "api-reference.html"
    config = set_canonical_url(config, file_name)
    content = Templates.api_reference_template(config, modules, exceptions, protocols)
    File.write!("#{output}/#{file_name}", content)
  end

  defp generate_not_found(modules, exceptions, protocols, output, config) do
    file_name = "404.html"
    config = set_canonical_url(config, file_name)
    content = Templates.not_found_template(config, modules, exceptions, protocols)
    File.write!("#{output}/#{file_name}", content)
    [file_name]
  end

  defp generate_sidebar_items(modules, exceptions, protocols, extras, output) do
    sidebar_items = "dist/sidebar_items.js"
    nodes = %{modules: modules, protocols: protocols,
              exceptions: exceptions, extras: extras}
    content = Templates.create_sidebar_items(nodes)
    File.write!(Path.join(output, sidebar_items), content)
    [sidebar_items]
  end

  defp assets do
    [{"dist/*.{css,js}", "dist"},
     {"fonts/*.{eot,svg,ttf,woff,woff2}", "fonts"}]
  end

  @doc """
  Copy a list of assets into a given directory
  """
  @spec generate_assets(list, String.t) :: :ok
  def generate_assets(source, output) do
    Enum.flat_map source, fn {pattern, dir} ->
      output = "#{output}/#{dir}"
      File.mkdir output

      Enum.map Path.wildcard(pattern), fn(file) ->
        base = Path.basename(file)
        File.copy file, "#{output}/#{base}"
        "#{dir}/#{base}"
      end
    end
  end

  defp generate_extras(output, module_nodes, modules, exceptions, protocols, config) do
    extras =
      config.extras
      |> Enum.map(&Task.async(fn ->
          generate_extra(&1, output, module_nodes, modules, exceptions, protocols, config)
         end))
      |> Enum.map(&Task.await(&1, :infinity))

    api_reference_headers =
      if(Enum.empty?(modules),    do: [], else: [{"Modules", "modules"}]) ++
      if(Enum.empty?(exceptions), do: [], else: [{"Exceptions", "exceptions"}]) ++
      if(Enum.empty?(protocols),  do: [], else: [{"Protocols", "protocols"}])

    [{"api-reference", "API Reference", api_reference_headers}|extras]
  end

  defp generate_extra({input_file, options}, output, module_nodes, modules, exceptions, protocols, config) do
    input_file = to_string(input_file)
    filename = options[:filename] || input_file |> input_to_title() |> title_to_filename()

    options = %{
      title: options[:title],
      input: input_file,
      output: "#{output}/#{filename}.html",
      filename: filename
    }

    create_extra_files(module_nodes, modules, exceptions, protocols, config, options)
  end

  defp generate_extra(input, output, module_nodes, modules, exceptions, protocols, config) do
    filename = input |> input_to_title |> title_to_filename

    options = %{
      title: nil,
      input: input,
      output: "#{output}/#{filename}.html",
      filename: filename
    }

    create_extra_files(module_nodes, modules, exceptions, protocols, config, options)
  end

  defp create_extra_files(module_nodes, modules, exceptions, protocols, config, options) do
    if valid_extension_name?(options.input) do
      content =
        options.input
        |> File.read!()
        |> Autolink.project_doc(module_nodes)

      html_content = ExDoc.Markdown.to_html(content)
      title = options.title || extract_title(html_content) || input_to_title(options[:input])

      config = set_canonical_url(config, options.filename)
      html = Templates.extra_template(config, title, modules,
                                      exceptions, protocols, html_content)

      if File.regular? options.output do
        IO.puts "warning: file #{Path.basename options.output} already exists"
      end

      File.write!(options.output, html)
      {options.filename, title, extract_headers(html_content)}
    else
      raise ArgumentError, "file format not recognized, allowed format is: .md"
    end
  end

  def valid_extension_name?(input) do
    file_ext =
      input
      |> Path.extname()
      |> String.downcase()

    if file_ext in [".md"] do
      true
    else
      false
    end
  end

  @tag_regex ~r/<[^>]*>/m

  defp strip_html(header) do
    Regex.replace(@tag_regex, header, "")
  end

  @h1_regex ~r/<h1.*?>(.+)<\/h1>/m

  defp extract_title(content) do
    title = Regex.run(@h1_regex, content, capture: :all_but_first)

    if title do
      title |> List.first |> strip_html |> String.strip
    end
  end

  @h2_regex  ~r/<h2.*?>(.+)<\/h2>/m

  defp extract_headers(content) do
    @h2_regex
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&{&1, Templates.header_to_id(&1)})
  end

  defp input_to_title(input) do
    input |> Path.basename() |> Path.rootname()
  end

  defp title_to_filename(title) do
    title |> String.replace(" ", "-") |> String.downcase()
  end

  def process_logo_metadata(config, output) do
    File.mkdir_p! output
    file_extname =
      config.logo
      |> Path.extname()
      |> String.downcase()

    if file_extname in ~w(.png .jpg) do
      file_name = "#{output}/logo#{file_extname}"
      File.copy!(config.logo, file_name)
      Map.put(config, :logo, Path.basename(file_name))
    else
      raise ArgumentError, "image format not recognized, allowed formats are: .jpg, .png"
    end
  end

  defp generate_redirect(output, file_name, config, redirect_to) do
    content = Templates.redirect_template(config, redirect_to)
    File.write!("#{output}/#{file_name}", content)
  end

  def filter_list(:modules, nodes) do
    Enum.filter nodes, &(not &1.type in [:exception, :protocol, :impl])
  end

  def filter_list(:exceptions, nodes) do
    Enum.filter nodes, &(&1.type in [:exception])
  end

  def filter_list(:protocols, nodes) do
    Enum.filter nodes, &(&1.type in [:protocol])
  end

  defp generate_list(nodes, modules, exceptions, protocols, output, config) do
    nodes
    |> Enum.map(&Task.async(fn ->
        generate_module_page(&1, modules, exceptions, protocols, output, config)
       end))
    |> Enum.map(&Task.await(&1, :infinity))
  end

  defp generate_module_page(node, modules, exceptions, protocols, output, config) do
    file_name = "#{node.id}.html"
    config = set_canonical_url(config, file_name)
    content = Templates.module_page(node, modules, exceptions, protocols, config)
    File.write!("#{output}/#{file_name}", content)
    file_name
  end

  def assets_path(patterns, formatter \\ "html") do
    Enum.into(patterns, [], fn {pattern, dir} ->
      {Application.app_dir(:ex_doc, "priv/ex_doc/formatter/#{formatter}/templates/#{pattern}"), dir}
    end)
  end

  defp set_canonical_url(config, file_name) do
    if config.canonical do
      canonical_url =
        config.canonical
        |> String.rstrip(?/)
        |> Path.join(file_name)

      Map.put(config, :canonical, canonical_url)
    else
      config
    end
  end
end
